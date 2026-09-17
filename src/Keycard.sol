// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Keycard — subscription access passes paid in native USDC on Arc
/// @notice A merchant publishes a plan priced in USDC. A subscriber pays in a single
///         transaction — no `approve`, no ERC-20 dance — because on Arc the money and
///         the gas are the same asset. A service gates access by reading `isActive`.
///
/// @dev Arc-specific behaviour this contract is built around:
///
///      1. USDC has two interfaces over ONE balance: the native token (18 decimals,
///         what arrives as `msg.value`) and an enshrined ERC-20 at
///         0x3600000000000000000000000000000000000000 (6 decimals). They are not
///         separate tokens. Mixing them silently misprices by 1e12 — an acknowledged
///         footgun (circlefin/arc-node#91). Every crossing of that boundary here goes
///         through `toNative`/`toUsdc` and nowhere else.
///
///      2. Prices are stored in 6-decimal USDC units, the representation the rest of
///         the ecosystem speaks. Only the payment comparison is lifted to 18 decimals.
///
///      3. Native value transfers revert if either party is blocklisted, and also for
///         the zero address and precompile addresses. A push payout to the merchant
///         would therefore let a blocked merchant brick every subscribe() call, so
///         funds are credited and withdrawn (pull), never pushed.
///
///      4. Payment remainders are credited, never truncated: Arc warns that fractional
///         amounts below 6 decimals persist onchain, so rounding them away would
///         quietly strand real money.
contract Keycard {
    /// @notice 1e18 native units == 1e6 ERC-20 units.
    uint256 internal constant DECIMAL_SCALE = 1e12;

    /// @notice The enshrined ERC-20 view of USDC. Value sent here would revert, so the
    ///         contract never transfers to it; it is exposed for integrators.
    address public constant USDC_ERC20 = 0x3600000000000000000000000000000000000000;

    /// @notice Upper bound on periods bought at once, keeping expiry arithmetic sane.
    uint256 public constant MAX_PERIODS = 60;

    struct Plan {
        address merchant;
        uint128 priceUsdc; // 6 decimals
        uint64 period; // seconds of access per period
        bool active;
        string name;
    }

    uint256 public planCount;
    mapping(uint256 => Plan) private _plans;

    /// @notice planId => subscriber => unix timestamp at which access lapses.
    mapping(uint256 => mapping(address => uint64)) public expiryOf;

    /// @notice Native (18-decimal) balance withdrawable by an address.
    mapping(address => uint256) public withdrawable;

    uint256 private _locked = 1;

    event PlanCreated(uint256 indexed planId, address indexed merchant, uint128 priceUsdc, uint64 period, string name);
    event PlanStatusChanged(uint256 indexed planId, bool active);
    event Subscribed(
        uint256 indexed planId, address indexed subscriber, uint256 periods, uint256 paidNative, uint64 expiry
    );
    event Credited(address indexed account, uint256 amountNative);
    event Withdrawn(address indexed account, uint256 amountNative);

    error ZeroMerchant();
    error ZeroPeriod();
    error NoSuchPlan();
    error PlanInactive();
    error BadPeriods();
    error Underpaid(uint256 requiredNative, uint256 sentNative);
    error NotMerchant();
    error NothingToWithdraw();
    error TransferFailed();

    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    // --- decimal boundary -------------------------------------------------

    /// @notice Convert a 6-decimal USDC amount to native 18-decimal units.
    function toNative(uint256 usdcAmount) public pure returns (uint256) {
        return usdcAmount * DECIMAL_SCALE;
    }

    /// @notice Convert native 18-decimal units down to 6-decimal USDC.
    /// @dev Truncating: use for display only, never for recording balances.
    function toUsdc(uint256 nativeAmount) public pure returns (uint256) {
        return nativeAmount / DECIMAL_SCALE;
    }

    // --- merchant ---------------------------------------------------------

    /// @notice Publish a plan. `priceUsdc` is in 6-decimal USDC; zero is allowed so a
    ///         merchant can run a free trial tier through the same rail.
    function createPlan(string calldata name, uint128 priceUsdc, uint64 period) external returns (uint256 planId) {
        if (msg.sender == address(0)) revert ZeroMerchant();
        if (period == 0) revert ZeroPeriod();

        planId = ++planCount;
        _plans[planId] = Plan({merchant: msg.sender, priceUsdc: priceUsdc, period: period, active: true, name: name});

        emit PlanCreated(planId, msg.sender, priceUsdc, period, name);
    }

    function setPlanActive(uint256 planId, bool active) external {
        Plan storage p = _plans[planId];
        if (p.merchant == address(0)) revert NoSuchPlan();
        if (p.merchant != msg.sender) revert NotMerchant();
        p.active = active;
        emit PlanStatusChanged(planId, active);
    }

    function getPlan(uint256 planId) external view returns (Plan memory) {
        Plan memory p = _plans[planId];
        if (p.merchant == address(0)) revert NoSuchPlan();
        return p;
    }

    // --- subscriber -------------------------------------------------------

    /// @notice Price `periods` of a plan, in both representations.
    /// @return native 18-decimal amount to send as msg.value
    /// @return usdc 6-decimal amount for display
    function quote(uint256 planId, uint256 periods) public view returns (uint256 native, uint256 usdc) {
        Plan storage p = _plans[planId];
        if (p.merchant == address(0)) revert NoSuchPlan();
        if (periods == 0 || periods > MAX_PERIODS) revert BadPeriods();
        usdc = uint256(p.priceUsdc) * periods;
        native = toNative(usdc);
    }

    /// @notice Buy or extend access. Overpayment is credited back to the payer rather
    ///         than refunded inline, so a blocklisted payer cannot revert the purchase.
    function subscribe(uint256 planId, uint256 periods) external payable nonReentrant returns (uint64 expiry) {
        Plan storage p = _plans[planId];
        if (p.merchant == address(0)) revert NoSuchPlan();
        if (!p.active) revert PlanInactive();

        (uint256 costNative,) = quote(planId, periods);
        if (msg.value < costNative) revert Underpaid(costNative, msg.value);

        // Extend from the later of now and the current expiry, so renewing early
        // never burns unused time.
        uint64 current = expiryOf[planId][msg.sender];
        // block.timestamp is the right clock here: the unit of account is a period of
        // days, and the seconds a validator could shave off are immaterial at that scale.
        // The cast is safe because uint64 seconds runs out in the year 2554.
        // forge-lint: disable-next-line(block-timestamp,unsafe-typecast)
        uint64 base = current > block.timestamp ? current : uint64(block.timestamp);
        // Explicit casts do not overflow-check, so widen, check, then narrow.
        uint256 newExpiry = uint256(base) + (uint256(p.period) * periods);
        if (newExpiry > type(uint64).max) revert BadPeriods();
        // forge-lint: disable-next-line(unsafe-typecast)
        expiry = uint64(newExpiry);
        expiryOf[planId][msg.sender] = expiry;

        withdrawable[p.merchant] += costNative;

        uint256 remainder = msg.value - costNative;
        if (remainder > 0) {
            withdrawable[msg.sender] += remainder;
            emit Credited(msg.sender, remainder);
        }

        emit Subscribed(planId, msg.sender, periods, costNative, expiry);
    }

    /// @notice The gate a service reads to decide whether to serve a subscriber.
    function isActive(uint256 planId, address subscriber) external view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return expiryOf[planId][subscriber] > block.timestamp;
    }

    /// @notice Seconds of access left, zero once lapsed.
    function remaining(uint256 planId, address subscriber) external view returns (uint256) {
        uint64 e = expiryOf[planId][subscriber];
        // forge-lint: disable-next-line(block-timestamp)
        return e > block.timestamp ? e - block.timestamp : 0;
    }

    // --- payouts ----------------------------------------------------------

    /// @notice Withdraw credited native USDC. Pull, not push: a merchant who cannot
    ///         receive value fails only their own withdrawal, never a subscriber's payment.
    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;

        // Emitted before the external call: the balance is already zeroed, so the log
        // is truthful, and off-chain consumers cannot be fed a reordered sequence.
        emit Withdrawn(msg.sender, amount);

        // The balance is zeroed before this call and `nonReentrant` is still held for
        // its duration, so a re-entering withdraw() hits the guard and reverts. The
        // full balance is sent deliberately — capping it would strand the remainder.
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
