// End-to-end check of index.html against the live contracts (Arbitrum Sepolia by default).
// A test wallet (EIP-1193) is injected into the page; signing happens in Node with a testnet-only key.
// usage: DEPLOYER_PRIVATE_KEY=... [CHAIN=robinhood-testnet] [RPC_URL=...] [ESCROW_ADDR=... TOKEN_ADDR=...] node e2e/run.mjs [--video <dir>]
// RPC_URL lets the same run go against a local anvil started with the chain's id (anvil --chain-id 46630).
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { ethers } = require("ethers");
const { chromium } = require(process.env.PW_PATH || "playwright");

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CHAINS = {
  "arbitrum-sepolia": { id: 421614, name: "Arbitrum Sepolia", rpc: "https://sepolia-rollup.arbitrum.io/rpc" },
  "robinhood-testnet": { id: 46630, name: "Robinhood Chain Testnet", rpc: "https://rpc.testnet.chain.robinhood.com" },
};
const CHAIN = process.env.CHAIN || "arbitrum-sepolia";
if (!CHAINS[CHAIN]) throw new Error("unknown CHAIN " + CHAIN);
const { id: CHAIN_ID, name: CHAIN_NAME } = CHAINS[CHAIN];
const RPC = process.env.RPC_URL || CHAINS[CHAIN].rpc;
const CHAIN_HEX = "0x" + CHAIN_ID.toString(16);
const videoIdx = process.argv.indexOf("--video");
const videoDir = videoIdx > 0 ? process.argv[videoIdx + 1] : null;

const rpc = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
const wallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, rpc);
const payee = ethers.Wallet.createRandom().address;
const arbiterWallet = ethers.Wallet.createRandom().connect(rpc);
const arbiter = arbiterWallet.address;
let active = wallet; // the account the injected wallet currently exposes

const server = http.createServer((req, res) => {
  const p = req.url.split("?")[0];
  const f = path.join(ROOT, p === "/" ? "index.html" : p);
  if (!f.startsWith(ROOT) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); fs.createReadStream(f).pipe(res);
}).listen(0, "127.0.0.1");
await new Promise(r => server.once("listening", r));
const url = `http://127.0.0.1:${server.address().port}/`;

async function handle(method, params) {
  switch (method) {
    case "eth_requestAccounts": case "eth_accounts": return [active.address];
    case "eth_chainId": return CHAIN_HEX;
    case "net_version": return String(CHAIN_ID);
    case "wallet_switchEthereumChain": case "wallet_addEthereumChain": return null;
    case "eth_sendTransaction": {
      const t = params[0];
      const tx = await active.sendTransaction({ to: t.to, data: t.data, value: t.value ? BigInt(t.value) : 0n,
        gasLimit: t.gas ? BigInt(t.gas) : undefined });
      return tx.hash;
    }
    default: return rpc.send(method, params || []);
  }
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 },
  ...(videoDir ? { recordVideo: { dir: videoDir, size: { width: 1280, height: 860 } } } : {}) });
// E2E_OFFLINE=1 serves the page's pinned ethers build from node_modules (for machines without CDN access).
if (process.env.E2E_OFFLINE) await ctx.route(/cdn\.jsdelivr\.net\/npm\/ethers@/, r => r.fulfill({ path: path.join(path.dirname(require.resolve("ethers")), "../dist/ethers.umd.min.js") }));
await ctx.exposeBinding("__wallet", async (_src, method, params) => {
  try { return { ok: await handle(method, params) }; } catch (e) { return { err: e.shortMessage || e.message }; }
});
await ctx.addInitScript(() => {
  const listeners = {};
  window.ethereum = {
    isMetaMask: true,
    request: async ({ method, params }) => {
      const r = await window.__wallet(method, params);
      if (r.err) throw Object.assign(new Error(r.err), { code: -32603 });
      return r.ok;
    },
    on: (ev, fn) => { (listeners[ev] ||= []).push(fn); },
    removeListener: () => {},
  };
});

const page = await ctx.newPage();
const logText = () => page.locator("#log").innerText().catch(() => "");
async function waitLog(re, ms = 120000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const t = await logText();
    if (/failed:/.test(t)) throw new Error("UI error: " + t.split("\n").filter(l => /failed:/.test(l)).pop());
    if (re.test(t)) return t;
    await page.waitForTimeout(500);
  }
  throw new Error("timeout waiting for " + re);
}
const pause = ms => page.waitForTimeout(videoDir ? ms : 200);
async function caption(text) {
  if (!videoDir) return;
  await page.evaluate(t => {
    let d = document.getElementById("__cap");
    if (!d) { d = document.createElement("div"); d.id = "__cap";
      d.style.cssText = "position:fixed;left:0;right:0;bottom:0;padding:14px 24px;background:rgba(15,23,42,.88);color:#fff;font:600 20px/1.4 system-ui,sans-serif;z-index:99999;text-align:center";
      document.body.appendChild(d); }
    d.textContent = t;
  }, text);
  await page.waitForTimeout(1800);
}
const results = [];
const step = async (name, fn) => { const t0 = Date.now(); await fn(); results.push(`${name}: ok (${((Date.now() - t0) / 1000).toFixed(1)} s)`); };

try {
  await page.goto(url + "?chain=" + CHAIN); await pause(1500);
  if (process.env.ESCROW_ADDR) { await page.fill("#escrowAddr", process.env.ESCROW_ADDR); await page.dispatchEvent("#escrowAddr", "change"); }
  if (process.env.TOKEN_ADDR) { await page.fill("#tokenAddr", process.env.TOKEN_ADDR); await page.dispatchEvent("#tokenAddr", "change"); }
  await caption("MilestoneEscrow: milestone payments in USDG for cross-border freelancers, live on " + CHAIN_NAME);
  await step("connect", async () => { await page.click("#connect"); await waitLog(/Connected 0x/); });
  await pause(1000);
  const T = ethers.getAddress(await page.inputValue("#tokenAddr"));
  const tok = new ethers.Contract(T, ["function balanceOf(address) view returns (uint256)"], rpc);
  await caption("The client gets test USDG (mock token, 6 decimals) from the faucet");
  await step("faucet (mint 1000 mUSDG)", async () => { await page.click("#faucet"); await waitLog(/Faucet confirmed/); });
  await pause(1000);
  await caption("The client creates a job: payee, a neutral arbiter, and two milestones (100 + 200 USDG) with deadlines");
  await page.fill("#payee", payee); await pause(500);
  await page.fill("#arbiter", arbiter); await pause(800);
  await step("create job (100 + 200)", async () => { await page.click("#create"); await waitLog(/Job ID \d+/); });
  const jobId = await page.inputValue("#jobId");
  await pause(1500);
  await caption("The client locks the full 300 USDG in the escrow before work starts");
  await step("deposit 300", async () => { await page.click("#fund"); await waitLog(/Deposit confirmed/); await page.waitForFunction(() => /\| funded$/.test(document.getElementById("jobInfo").textContent)); });
  await pause(1500);
  await caption("Milestone #0 delivered: the client approves and 100 USDG goes straight to the freelancer");
  await step("approve milestone #0", async () => {
    await page.locator(".ms").nth(0).locator("button", { hasText: "Approve" }).click();
    await waitLog(/Approve confirmed/); await page.waitForSelector(".ms >> nth=0 >> .tag");
  });
  await pause(1500);
  await caption("Milestone #1 is contested: either side can freeze it with a dispute");
  await step("dispute milestone #1", async () => {
    await page.locator(".ms").nth(1).locator("button", { hasText: "Dispute" }).click();
    await waitLog(/Dispute confirmed/);
  });
  await pause(1500);
  if (videoDir) {
    const gas = await wallet.sendTransaction({ to: arbiter, value: ethers.parseEther("0.0003") }); await gas.wait();
    active = arbiterWallet;
    await caption("Now the arbiter connects with their own wallet");
    await page.click("#connect"); await waitLog(new RegExp("Connected " + arbiter));
    await page.click("#load"); await page.waitForTimeout(3000);
    await pause(1000);
    await caption("The arbiter splits the disputed milestone 50/50: 100 USDG to each side");
    await step("resolve 50/50", async () => {
      await page.locator(".ms").nth(1).locator("button", { hasText: "Resolve: 50/50" }).click();
      await waitLog(/Resolve: 50\/50 confirmed/);
    });
    await pause(1500);
    await caption("Every milestone settled exactly once. No admin, no fees, funds only move to client, payee or by the arbiter's split.");
    await pause(2500);
  }
  const payeeBal = await tok.balanceOf(payee);
  const tags = await page.locator(".ms .tag").allInnerTexts();
  results.push(`job ${jobId}; payee balance ${ethers.formatUnits(payeeBal, 6)}; milestone states ${tags.join(", ")}`);
  if (payeeBal !== ethers.parseUnits(videoDir ? "200" : "100", 6)) throw new Error("payee balance mismatch: " + payeeBal);
  results.push("RESULT: PASS");
} catch (e) {
  results.push("RESULT: FAIL " + e.message);
  await page.screenshot({ path: path.join(ROOT, "e2e", "fail.png") }).catch(() => {});
} finally {
  console.log(results.join("\n"));
  console.log("log:\n" + (await logText()));
  await ctx.close(); await browser.close(); server.close();
}
