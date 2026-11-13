// End-to-end check of index.html against the live Arbitrum Sepolia contracts.
// A test wallet (EIP-1193) is injected into the page; signing happens in Node with a testnet-only key.
// usage: DEPLOYER_PRIVATE_KEY=... node e2e/run.mjs [--video <dir>]
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { ethers } = require("ethers");
const { chromium } = require(process.env.PW_PATH || "playwright");

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const RPC = "https://sepolia-rollup.arbitrum.io/rpc";
const CHAIN_HEX = "0x66eee"; // 421614
const videoIdx = process.argv.indexOf("--video");
const videoDir = videoIdx > 0 ? process.argv[videoIdx + 1] : null;

const rpc = new ethers.JsonRpcProvider(RPC, 421614, { staticNetwork: true });
const wallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, rpc);
const payee = ethers.Wallet.createRandom().address;
const arbiter = ethers.Wallet.createRandom().address;

const server = http.createServer((req, res) => {
  const f = path.join(ROOT, req.url === "/" ? "index.html" : req.url.split("?")[0]);
  if (!f.startsWith(ROOT) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); fs.createReadStream(f).pipe(res);
}).listen(0, "127.0.0.1");
await new Promise(r => server.once("listening", r));
const url = `http://127.0.0.1:${server.address().port}/`;

async function handle(method, params) {
  switch (method) {
    case "eth_requestAccounts": case "eth_accounts": return [wallet.address];
    case "eth_chainId": return CHAIN_HEX;
    case "net_version": return "421614";
    case "wallet_switchEthereumChain": case "wallet_addEthereumChain": return null;
    case "eth_sendTransaction": {
      const t = params[0];
      const tx = await wallet.sendTransaction({ to: t.to, data: t.data, value: t.value ? BigInt(t.value) : 0n,
        gasLimit: t.gas ? BigInt(t.gas) : undefined });
      return tx.hash;
    }
    default: return rpc.send(method, params || []);
  }
}

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 },
  ...(videoDir ? { recordVideo: { dir: videoDir, size: { width: 1280, height: 860 } } } : {}) });
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
const results = [];
const step = async (name, fn) => { const t0 = Date.now(); await fn(); results.push(`${name}: ok (${((Date.now() - t0) / 1000).toFixed(1)} s)`); };

try {
  await page.goto(url); await pause(1500);
  await step("connect", async () => { await page.click("#connect"); await waitLog(/Connected 0x/); });
  await pause(1000);
  const T = ethers.getAddress(await page.inputValue("#tokenAddr"));
  const tok = new ethers.Contract(T, ["function balanceOf(address) view returns (uint256)"], rpc);
  await step("faucet (mint 1000 mUSDG)", async () => { await page.click("#faucet"); await waitLog(/Faucet confirmed/); });
  await pause(1000);
  await page.fill("#payee", payee); await pause(500);
  await page.fill("#arbiter", arbiter); await pause(800);
  await step("create job (100 + 200)", async () => { await page.click("#create"); await waitLog(/Job ID \d+/); });
  const jobId = await page.inputValue("#jobId");
  await pause(1500);
  await step("deposit 300", async () => { await page.click("#fund"); await waitLog(/Deposit confirmed/); await page.waitForFunction(() => /\| funded$/.test(document.getElementById("jobInfo").textContent)); });
  await pause(1500);
  await step("approve milestone #0", async () => {
    await page.locator(".ms").nth(0).locator("button", { hasText: "Approve" }).click();
    await waitLog(/Approve confirmed/); await page.waitForSelector(".ms >> nth=0 >> .tag");
  });
  await pause(1500);
  await step("dispute milestone #1", async () => {
    await page.locator(".ms").nth(1).locator("button", { hasText: "Dispute" }).click();
    await waitLog(/Dispute confirmed/);
  });
  await pause(2500);
  const payeeBal = await tok.balanceOf(payee);
  const tags = await page.locator(".ms .tag").allInnerTexts();
  results.push(`job ${jobId}; payee balance ${ethers.formatUnits(payeeBal, 6)}; milestone states ${tags.join(", ")}`);
  if (payeeBal !== ethers.parseUnits("100", 6)) throw new Error("payee balance mismatch: " + payeeBal);
  results.push("RESULT: PASS");
} catch (e) {
  results.push("RESULT: FAIL " + e.message);
  await page.screenshot({ path: path.join(ROOT, "e2e", "fail.png") }).catch(() => {});
} finally {
  console.log(results.join("\n"));
  console.log("log:\n" + (await logText()));
  await ctx.close(); await browser.close(); server.close();
}
