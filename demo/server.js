// Keycard demo service — a real service gated by an Arc mainnet subscription.
//
// The point of this file: a service does not need a crypto stack to accept money.
// It needs one eth_call. No SDK, no dependencies, no webhooks, no payment provider
// holding the funds — the subscription state IS the chain state.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const RPC_URL = process.env.ARC_RPC_URL ?? "https://rpc.mainnet.arc.io";
const CONTRACT = (process.env.KEYCARD_ADDRESS ?? "").toLowerCase();
const PLAN_ID = BigInt(process.env.KEYCARD_PLAN_ID ?? "1");
const PORT = Number(process.env.PORT ?? 8787);

// Selectors, computed with `cast sig`. Hand-encoding keeps this file dependency-free.
const SEL_IS_ACTIVE = "0xbab0ac03"; // isActive(uint256,address)
const SEL_EXPIRY_OF = "0x13c6209a"; // expiryOf(uint256,address)
const SEL_QUOTE = "0x315f1a41"; // quote(uint256,uint256)

const pad = (hex) => hex.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const encUint = (n) => pad(BigInt(n).toString(16));
const encAddr = (a) => pad(a);

let rpcId = 0;

async function ethCall(data) {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: ++rpcId,
      method: "eth_call",
      params: [{ to: CONTRACT, data }, "latest"],
    }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`RPC: ${json.error.message}`);
  return json.result;
}

/// The whole integration: one call, one boolean.
async function isActive(subscriber) {
  const result = await ethCall(SEL_IS_ACTIVE + encUint(PLAN_ID) + encAddr(subscriber));
  return BigInt(result) === 1n;
}

async function expiryOf(subscriber) {
  const result = await ethCall(SEL_EXPIRY_OF + encUint(PLAN_ID) + encAddr(subscriber));
  return Number(BigInt(result));
}

async function quote(periods) {
  const result = await ethCall(SEL_QUOTE + encUint(PLAN_ID) + encUint(periods));
  const body = result.replace(/^0x/, "");
  return {
    native: BigInt("0x" + body.slice(0, 64)).toString(), // 18 decimals, send as msg.value
    usdc: BigInt("0x" + body.slice(64, 128)).toString(), // 6 decimals, show to humans
  };
}

const isAddress = (a) => typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a);

function send(res, status, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
  });
  res.end(body);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const address = url.searchParams.get("address");

  try {
    if (url.pathname === "/" || url.pathname === "/index.html") {
      // One page, served here or statically from GitHub Pages — it works either way.
      const html = await readFile(join(__dirname, "..", "docs", "index.html"), "utf8");
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    if (url.pathname === "/api/config") {
      return send(res, 200, {
        contract: CONTRACT,
        planId: PLAN_ID.toString(),
        chainId: 5042,
        rpcUrl: RPC_URL,
        explorer: "https://explorer.arc.io",
        price: await quote(1),
      });
    }

    if (url.pathname === "/api/status") {
      if (!isAddress(address)) return send(res, 400, { error: "valid ?address= required" });
      const [active, expiry] = await Promise.all([isActive(address), expiryOf(address)]);
      const now = Math.floor(Date.now() / 1000);
      return send(res, 200, {
        address,
        active,
        expiry,
        expiresAt: expiry ? new Date(expiry * 1000).toISOString() : null,
        secondsRemaining: expiry > now ? expiry - now : 0,
      });
    }

    // The gate itself.
    if (url.pathname === "/api/content") {
      if (!isAddress(address)) return send(res, 400, { error: "valid ?address= required" });

      if (!(await isActive(address))) {
        return send(res, 402, {
          error: "Payment Required",
          detail: "No active Keycard for this address on plan " + PLAN_ID,
          howToFix: "Call subscribe() on the Keycard contract, then retry.",
        });
      }

      const expiry = await expiryOf(address);
      return send(res, 200, {
        granted: true,
        subscriber: address,
        expiresAt: new Date(expiry * 1000).toISOString(),
        payload: {
          note: "This is the protected resource. The service released it because the chain said the subscription is live.",
          issuedAt: new Date().toISOString(),
        },
      });
    }

    return send(res, 404, { error: "not found" });
  } catch (err) {
    return send(res, 502, { error: String(err.message ?? err) });
  }
});

if (!CONTRACT) {
  console.error("Set KEYCARD_ADDRESS to the deployed Keycard contract address.");
  process.exit(1);
}

server.listen(PORT, () => {
  console.log(`Keycard demo service on http://localhost:${PORT}`);
  console.log(`  contract ${CONTRACT}  plan ${PLAN_ID}  via ${RPC_URL}`);
});
