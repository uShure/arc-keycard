# Arc Microgrants — submission draft

**Project name:** Keycard

**One-liner:** Subscription access passes paid in native USDC on Arc — one transaction to buy,
one `eth_call` to check.

**Links**

| Field | Value |
|---|---|
| Live deployment | `https://explorer.arc.io/address/<DEPLOYED_ADDRESS>` |
| Demo | https://ushure.github.io/arc-keycard/ |
| Repo | https://github.com/uShure/arc-keycard |
| Builder profile | https://github.com/uShure |
| Chain | Arc mainnet (5042) |

---

## What it does

A merchant publishes a subscription plan priced in USDC. A subscriber buys access in a single
transaction. A service decides whether to serve a request by asking the chain one question:
`isActive(planId, address)`.

There is no payment provider holding the money, no webhook that has to stay in sync, and no
database row that can drift from reality. The subscription *is* chain state, and expiry needs
no cron job because a lapsed pass simply stops answering true.

The demo page is static and talks to Arc directly, so the gate you see is the real contract
state. `demo/server.js` is the same gate server-side: a plain HTTP service, zero dependencies,
that answers `402 Payment Required` without an active pass and serves the resource with one.

## What it uses Arc for

Everywhere else, taking a stablecoin payment is two transactions and a token approval, because
the gas asset and the money are different things. On Arc they are the same asset, so
`subscribe()` is simply `payable` and the user needs one balance of one thing.

That convenience hides a real trap, and handling it correctly is most of what this project is.

**The 10¹² footgun.** Arc exposes USDC through two interfaces over one balance: native at 18
decimals (`msg.value`, gas, `eth_getBalance`) and an enshrined ERC-20 at `0x3600…0000` at 6
decimals. Mix them and every amount is wrong by a factor of 10¹² — silently, with no revert.
It is open in Circle's own tracker as
[arc-node#91](https://github.com/circlefin/arc-node/issues/91).

Keycard crosses that boundary in exactly two functions and nowhere else. Prices are stored in
6-decimal USDC, the representation the ecosystem speaks, and lifted to 18 only to check the
payment. A test pays the 6-decimal figure as if it were native — the mistake an experienced
EVM developer makes on day one here — and asserts it reverts loudly instead of quietly selling
a month of access for 0.000000000005 USDC.

**Three Arc runtime divergences shaped the design:**

1. Value transfers revert when either party is blocklisted, so an inline payout would let a
   blocked merchant brick `subscribe()` for all of their subscribers. Payouts are pull, not
   push: a merchant who cannot receive value fails only their own withdrawal. A test proves a
   subscriber still gets access in that case.
2. Fractional amounts below 6 decimals persist onchain, and Arc's docs warn against recording
   balances from truncated values. Overpayment is credited to the wei, dust included. A fuzz
   test asserts merchant credit plus payer credit always equals exactly what was sent.
3. Transfers to precompile addresses revert, so the contract never sends value to `0x3600…0000`.

## Technical credibility

- 25 tests including fuzz, `forge lint` clean.
- Verified end to end against a fork of Arc mainnet before spending anything on mainnet.
- Compiled with solc 0.8.28 targeting `cancun`: Arc's baseline is Osaka, solc has no `osaka`
  target yet, and `cancun` emits only opcodes Osaka still honours.

While validating, a withdrawal on the fork succeeded, the contract's balance went to zero and
the merchant's did not move. The trace showed why: Anvil's default account — the one whose
private key is in every tutorial — is **not an EOA on Arc mainnet**. It holds 23 bytes of
forwarder code that sweeps anything sent to it, and the destination has collected real USDC
this way. Deploy to Arc with a well-known test key and the funds leave on arrival. That finding
is written up in the README as a warning to other builders.

## Honest limits

A proof of concept, not a product. No upgradeability and no admin key — deliberate, but it
means a published plan cannot be edited, only replaced. One merchant, flat pricing, no
proration or refunds of unused time. The demo gate trusts the address in the query string; a
production gate would bind it to a session with an EIP-4361 signature challenge, which is
orthogonal to what this demonstrates and so is left out rather than half-done.

## Worth taking further

The obvious next step is the missing half of a real payment rail: recurring renewal without a
manual transaction each period, proration, and a signed-session gate. The interesting question
underneath is whether an onchain subscription can be cheap enough to replace a payment
processor for small merchants. On Arc, where a transfer costs about $0.001 and settles on
inclusion, that stops being rhetorical.
