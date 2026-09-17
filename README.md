# Keycard

**Subscription access passes paid in native USDC, on Arc mainnet.**

A merchant publishes a plan priced in USDC. A subscriber pays in **one transaction** — no
`approve`, no ERC-20 dance, no payment provider sitting on the money. A service decides
whether to serve a request with **one `eth_call`**.

That is the whole integration. The subscription is not a row in someone's database that a
webhook is supposed to keep in sync. It *is* chain state.

---

## Why this belongs on Arc specifically

On every other EVM chain, taking a stablecoin payment is two transactions and a token
approval, because the gas asset and the money are different things. On Arc they are the
same asset: USDC is the native token. So `subscribe()` is `payable`, the payment arrives as
`msg.value`, and the user needs exactly one balance of exactly one thing.

The catch is that this convenience hides a genuine trap, and building on it correctly is
most of what this project is about.

### The 10¹² footgun

Arc exposes USDC through two interfaces over **one balance**:

| Interface | Address | Decimals | Where you meet it |
|---|---|---|---|
| Native token | `0xEeee…` | **18** | `msg.value`, `eth_getBalance`, gas, receipts |
| Enshrined ERC-20 | `0x3600000000000000000000000000000000000000` | **6** | `balanceOf`, `transfer`, every UI |

They are not separate tokens. Mix them without converting and every amount is wrong by a
factor of **10¹²** — silently, with no error, no revert, no warning. This is a known and
still-open problem in Arc's own tracker:
[circlefin/arc-node#91](https://github.com/circlefin/arc-node/issues/91).

Verified against mainnet while building this — one address, two readings of the same money:

```
$ cast balance 0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE   # native, 18dp
35620930501000000000000
$ cast call 0x3600…0000 "balanceOf(address)(uint256)" 0x7777…00eE   # ERC-20, 6dp
35620930501
```

Keycard crosses that boundary in exactly two functions, `toNative` and `toUsdc`, and
nowhere else. Prices are stored in **6-decimal USDC** — the representation the rest of the
ecosystem speaks — and lifted to 18 decimals only to check the payment.

There is a test that pays the 6-decimal number as if it were native, which is the mistake
an experienced EVM developer will actually make on their first day here. It reverts loudly
with `Underpaid(required, sent)` instead of quietly selling a month of access for
0.000000000005 USDC.

---

## Arc's runtime is not Ethereum's, and the design follows from that

Three divergences in [Arc's EVM differences](https://docs.arc.io/arc/references/evm-differences)
shaped this contract:

**1. Value transfers revert if either party is blocklisted.**
So paying the merchant inline would mean a blocked merchant bricks `subscribe()` for every
subscriber they have. Payouts are therefore **pull, not push**: funds are credited to a
balance the merchant withdraws themselves. A merchant who cannot receive value fails only
their own withdrawal. There is a test that proves a subscriber still gets access when the
merchant is unable to accept funds.

**2. Fractional amounts below 6 decimals persist onchain**, and Arc's docs warn explicitly
against recording balances from truncated 6-decimal values. Overpayment is credited to the
payer down to the last wei rather than rounded away — including dust so small that
`toUsdc()` reports it as zero. A fuzz test asserts that merchant credit plus payer credit
always equals exactly what was sent: no value created, none lost.

**3. Transfers to precompile addresses revert.** The contract never sends value to
`0x3600…0000`; that address is exposed as a constant for integrators and nothing more.

Also worth knowing: native sends emit standard ERC-20 `Transfer` logs (EIP-7708), so
payments made through Keycard show up in explorers and indexers as ordinary USDC transfers.

### A live trap worth knowing about

While validating this against a fork of Arc mainnet, a withdrawal succeeded, the contract's
balance went to zero, and the merchant's balance did not move. The trace explained it:

```
0x959922…::withdraw()
  ├─ emit Withdrawn(account: 0xf39Fd6…92266, amountNative: 1000000000000000000)
  ├─ 0xf39Fd6…92266::receive{value: 1000000000000000000}()
  │   └─ 0x369c91…8370::receive{value: 1000000000000000000}()
```

The "merchant" was Anvil's default account, `0xf39Fd6…92266` — an address whose private key
is published in every tutorial. On Arc mainnet that address is **not an EOA**: it holds 23
bytes of forwarder code that sweeps anything sent to it to `0x369c91…8370`, which has
collected real USDC this way.

```
$ cast code 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url https://rpc.mainnet.arc.io
0x363d3d373d3d3d363d73...   # 23 bytes, a minimal forwarder
```

Deploy to Arc with a well-known test key and your funds leave on arrival. Use a fresh key.
The contract itself was never at fault — on a clean chain the same flow balances to the wei,
which `test_withdrawClearsBalance` asserts.

---

## What is in here

```
src/Keycard.sol        the contract
test/Keycard.t.sol     25 tests, including fuzz
script/Deploy.s.sol    deployment + one demo plan
docs/index.html        the live demo: connect, pay, watch the gate open
demo/server.js         the same gate server-side — a real HTTP service (zero dependencies)
```

The demo service is the point of the whole exercise: it shows a plain HTTP service
accepting money with no crypto stack. No SDK, no library, no dependency — a `fetch` to an
RPC endpoint and a boolean:

```js
async function isActive(subscriber) {
  const result = await ethCall(SEL_IS_ACTIVE + encUint(PLAN_ID) + encAddr(subscriber));
  return BigInt(result) === 1n;
}
```

With no active pass the service answers `402 Payment Required`. With one, it serves the
resource. It re-checks on every request, so expiry needs no cron job and no cleanup.

---

## Live on Arc mainnet

| | |
|---|---|
| Contract | `0x99b9Be4bd5D6aFdCc2241e2Cac1Ccf7B34903988` |
| Explorer | https://explorer.arc.io/address/0x99b9Be4bd5D6aFdCc2241e2Cac1Ccf7B34903988 |
| Demo | https://ushure.github.io/arc-keycard/ |
| Chain | Arc mainnet, chain ID **5042** |

The demo page is static and talks to Arc directly, so the gate you see is the real contract
state, not a server's opinion of it.

### The whole loop, on mainnet, with real money

Not a testnet rehearsal. A merchant published a plan, a different address paid for it, and the
merchant took the revenue out — every step is a transaction anyone can open:

| Step | Transaction |
|---|---|
| Deploy | [`0xf8d30abe…01ad51`](https://explorer.arc.io/tx/0xf8d30abe7a9c6fa2812298c000e112a9124769a784ff11846e4fd8c00501ad51) |
| `createPlan` — 1.00 USDC / 30 days | [`0x9d5cebad…5cba5d`](https://explorer.arc.io/tx/0x9d5cebad46723101eace77763cff931b5fa7b4d1d2fc95fd7695ce9fc55cba5d) |
| `subscribe` — one transaction, no approve | [`0x329c014e…f0ac0d`](https://explorer.arc.io/tx/0x329c014e1dc176af2dfe4cb01521996dd6a0dc125f3213bbbad9eea041f0ac0d) |
| `withdraw` — merchant pulls the revenue | [`0x2c84d0e5…3485ae`](https://explorer.arc.io/tx/0x2c84d0e51127406c86dfcfc057d09eebdf50c07aa5bb87e645730ce0953485ae) |

Merchant `0x43593D89fBE5E89DBe25a4c4686b07B20f6d9396`, subscriber
`0x9109F545B7417329fD98c5f3c552BfD68030D96c`. Check the result yourself without trusting this
table:

```bash
cast call 0x99b9Be4bd5D6aFdCc2241e2Cac1Ccf7B34903988 \
  "isActive(uint256,address)(bool)" 1 0x9109F545B7417329fD98c5f3c552BfD68030D96c \
  --rpc-url https://rpc.mainnet.arc.io
# true
```

Afterwards the contract holds nothing and `withdrawable` is zero for everyone: no dust
stranded, no balance left behind. Deployment cost **0.022999392 USDC** and the entire
buy-and-settle loop cost about **0.0027 USDC** in gas — the dollar itself went to the merchant.

---

## Running it

```bash
# tests
forge test

# deploy (gas is USDC; this costs roughly 0.03 USDC at Arc's 20 Gwei floor)
forge script script/Deploy.s.sol:Deploy --rpc-url arc --private-key $ARC_DEPLOYER_KEY --broadcast

# the gated service
cd demo
KEYCARD_ADDRESS=0x... KEYCARD_PLAN_ID=1 npm start
```

Compiled with solc 0.8.28 targeting `cancun`. Arc's baseline is the Osaka hard fork; solc
has no `osaka` target yet, and `cancun` emits only opcodes Osaka still honours.

---

## Honest limits

This is a proof of concept, not a product.

- **No upgradeability and no admin key.** Deliberate — there is nobody to trust, but also no
  way to fix a plan once published. A merchant republishes instead.
- **Time is `block.timestamp`.** Fine at the granularity of a subscription period; validators
  could nudge it by seconds, which does not matter when the unit is 30 days.
- **One plan, one merchant, flat pricing.** No proration, no discounts, no refunds of unused
  time. Each of those is a real design question, not an afternoon of work.
- **The demo service trusts the address in the query string.** A production gate would bind
  the address to a session with a signature challenge (EIP-4361). That is orthogonal to what
  this project is demonstrating, so it is left out rather than half-done.

## License

MIT
