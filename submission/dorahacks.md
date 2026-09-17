# Keycard: subscriptions paid in native USDC on Arc

**Try it:** [Live demo](https://ushure.github.io/arc-keycard/) · [Contract on Arcscan](https://explorer.arc.io/address/0x99b9Be4bd5D6aFdCc2241e2Cac1Ccf7B34903988) · [Source code (MIT)](https://github.com/uShure/arc-keycard)

## Problem

Charging for access to a service means renting a payment processor. It takes a cut, it can
reverse a payment months later, it demands paperwork before it will pay out, and it tells your
service who paid through a webhook. That webhook is the weak point: the subscription your
database believes in is a copy of the truth, and copies drift. Every "why am I locked out, I
paid" support ticket is that drift.

Moving the payment onchain has not really fixed this, because on every other chain the money
and the gas are different assets. A stablecoin subscription becomes two transactions and a
token approval, and the user has to hold a volatile coin they never asked for just to spend the
dollars they did.

## Solution

Keycard is a subscription that lives on Arc. A merchant publishes a plan priced in USDC. A
subscriber buys access in **one transaction, with no approval step**, because on Arc USDC *is*
the native token — the money and the gas are the same thing. A service decides whether to serve
a request by asking the chain one question.

There is no processor holding the funds, no webhook to keep in sync, and no database row that
can disagree with reality. The subscription **is** chain state. A lapsed pass needs no cron job
to clean up; it simply stops answering true.

## Features

**For the merchant**
- Publish a plan with a price in USDC and a period of any length; free tiers are allowed, so a
  trial and a paid plan ride the same rail.
- Revenue accrues to a balance you withdraw yourself. Nobody can freeze it, and nobody has an
  admin key over it — including the author of the contract.
- Deactivate a plan to stop new sales without touching anyone's existing access.

**For the service**
- One `eth_call` is the entire integration: `isActive(planId, address)` returns a boolean.
- `remaining()` gives seconds left if you want to warn people before they lapse.
- No SDK, no library, no dependency. The reference implementation in `demo/server.js` is a
  plain Node HTTP server with an empty dependency list that answers `402 Payment Required`
  without a pass and serves the resource with one.

**For the subscriber**
- Pay once, in dollars, in a single transaction.
- Renew early and the unused time is added, not burned.
- Overpay and the remainder is credited back to you down to the last wei.

## How it works

The contract is 207 lines of Solidity — about half of them comments explaining the
Arc-specific reasoning — with no upgradeability and no owner. The demo page is
static HTML that talks to the RPC directly, so the gate a visitor sees is the real contract
state rather than a server's opinion of it. Both the page and the server hand-encode their
calls; there is no web3 library anywhere in this project.

### The 10¹² footgun, which is most of the work

Arc exposes USDC through two interfaces over **one balance**:

| Interface | Address | Decimals | Where you meet it |
|---|---|---|---|
| Native token | `0xEeee…` | **18** | `msg.value`, gas, `eth_getBalance` |
| Enshrined ERC-20 | `0x3600…0000` | **6** | `balanceOf`, `transfer`, every UI |

They are not separate tokens. Mix them without converting and every amount is wrong by a factor
of **10¹²** — silently, with no revert and no warning. It is open in Circle's own tracker as
[arc-node#91](https://github.com/circlefin/arc-node/issues/91), and confirmed on mainnet while
building this: one address, two readings of the same money.

Keycard crosses that boundary in exactly two functions, `toNative` and `toUsdc`, and nowhere
else. Prices are stored in 6-decimal USDC — the representation the rest of the ecosystem speaks
— and lifted to 18 decimals only to check the payment. There is a test that pays the 6-decimal
figure as if it were native, which is the mistake an experienced EVM developer makes on their
first day here; it reverts loudly with `Underpaid(required, sent)` instead of quietly selling a
month of access for 0.000000000005 USDC.

### Three Arc divergences that shaped the design

1. **Value transfers revert when either party is blocklisted.** Paying the merchant inline
   would therefore let a blocked merchant brick `subscribe()` for every subscriber they have.
   Payouts are pull, not push: a merchant who cannot receive value fails only their own
   withdrawal. A test proves a subscriber still gets access in that case.
2. **Fractional amounts below 6 decimals persist onchain**, and Arc's docs warn against
   recording balances from truncated values. Overpayment is credited to the wei, dust included.
   A fuzz test asserts merchant credit plus payer credit always equals exactly what was sent —
   no value created, none lost.
3. **Transfers to precompile addresses revert**, so the contract never sends value to
   `0x3600…0000`. That address is exposed as a constant for integrators and nothing more.

## Proof it works

Not a testnet rehearsal. The whole loop ran on **Arc mainnet with real money** — a merchant
published a plan, a *different* address paid for it, and the merchant took the revenue out:

| Step | Transaction |
|---|---|
| Deploy | [`0xf8d30abe…01ad51`](https://explorer.arc.io/tx/0xf8d30abe7a9c6fa2812298c000e112a9124769a784ff11846e4fd8c00501ad51) |
| `createPlan` — 1.00 USDC / 30 days | [`0x9d5cebad…5cba5d`](https://explorer.arc.io/tx/0x9d5cebad46723101eace77763cff931b5fa7b4d1d2fc95fd7695ce9fc55cba5d) |
| `subscribe` — one tx, no approve | [`0x329c014e…f0ac0d`](https://explorer.arc.io/tx/0x329c014e1dc176af2dfe4cb01521996dd6a0dc125f3213bbbad9eea041f0ac0d) |
| `withdraw` — merchant pulls revenue | [`0x2c84d0e5…3485ae`](https://explorer.arc.io/tx/0x2c84d0e51127406c86dfcfc057d09eebdf50c07aa5bb87e645730ce0953485ae) |

Check the result yourself instead of trusting this page:

```bash
cast call 0x99b9Be4bd5D6aFdCc2241e2Cac1Ccf7B34903988 \
  "isActive(uint256,address)(bool)" 1 0x9109F545B7417329fD98c5f3c552BfD68030D96c \
  --rpc-url https://rpc.mainnet.arc.io   # true
```

Afterwards the contract holds nothing and `withdrawable` is zero for every party. Deployment
cost **0.0229994 USDC**; the entire buy-and-settle loop about **0.0027 USDC** in gas.

Also: 25 tests including fuzz, `forge lint` clean, and the whole flow validated against a fork
of Arc mainnet before a cent was spent.

### A live trap found on the way

During that fork validation a withdrawal succeeded, the contract's balance went to zero, and
the merchant's balance did not move. The trace explained it: the "merchant" was Anvil's default
account, whose private key appears in every tutorial. On Arc mainnet that address is **not an
EOA** — it holds 23 bytes of forwarder code that sweeps anything sent to it, and the
destination has collected real USDC this way. Deploy to Arc with a well-known test key and your
funds leave on arrival. It is written up in the README as a warning to other builders.

## Getting started

**As a subscriber:** open the [demo](https://ushure.github.io/arc-keycard/), connect a wallet
(it will offer to add Arc), and press Subscribe. One transaction, 1.00 USDC, and the gate on
the page unlocks.

**As a service:** one call decides everything.

```js
const active = await isActive(planId, address);   // demo/server.js, zero dependencies
if (!active) return res.writeHead(402).end();
```

**As a merchant:** call `createPlan(name, priceInUsdc6dp, periodSeconds)`, publish the plan id,
and call `withdraw()` whenever you like.

## What's next

The missing half of a real payment rail: renewal that does not need a manual transaction each
period, proration when someone upgrades mid-term, and a gate that binds the address to a
session with an EIP-4361 signature challenge rather than trusting a query parameter.

The question underneath is whether an onchain subscription can be cheap enough to replace a
payment processor for small merchants. On Arc, where this loop cost a third of a cent and
settles on inclusion, that stops being rhetorical.

**Known limits, stated plainly:** this is a proof of concept. No upgradeability and no admin
key is deliberate — there is nobody to trust, but also no way to edit a published plan, only to
replace it. One merchant per plan, flat pricing, no refunds of unused time. The demo gate
trusts the address in the query string, which is fine for a demonstration and not for
production.

## Addresses used

- **Keycard:** `0x99b9Be4bd5D6aFdCc2241e2Cac1Ccf7B34903988`
- **USDC (enshrined ERC-20 view):** `0x3600000000000000000000000000000000000000`
- **Merchant / deployer:** `0x43593D89fBE5E89DBe25a4c4686b07B20f6d9396`
- **Subscriber:** `0x9109F545B7417329fD98c5f3c552BfD68030D96c`
- **Chain:** Arc mainnet, chain ID 5042, RPC `https://rpc.mainnet.arc.io`
