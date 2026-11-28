// Write a deployment's addresses into index.html (DEPLOYED) and the README "Deployed" table.
// usage: node script/set-deployment.mjs <arbitrum-sepolia|robinhood-testnet> <MilestoneEscrow> <MockUSDG>
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CHAINS = {
  "arbitrum-sepolia": { label: "Arbitrum Sepolia (421614)", explorer: "https://sepolia.arbiscan.io" },
  "robinhood-testnet": { label: "Robinhood Chain Testnet (46630)", explorer: "https://explorer.testnet.chain.robinhood.com" },
};
const [key, esc, tok] = process.argv.slice(2);
const isAddr = a => /^0x[0-9a-fA-F]{40}$/.test(a || "");
if (!CHAINS[key] || !isAddr(esc) || !isAddr(tok)) {
  console.error("usage: node script/set-deployment.mjs <" + Object.keys(CHAINS).join("|") + "> <escrow> <token>");
  process.exit(2);
}

const htmlPath = path.join(ROOT, "index.html");
const html = fs.readFileSync(htmlPath, "utf8");
const re = new RegExp(`("${key}": \\{ e: )"[^"]*"(, t: )"[^"]*"( \\})`);
if (!re.test(html)) { console.error("DEPLOYED entry for " + key + " not found in index.html"); process.exit(1); }
fs.writeFileSync(htmlPath, html.replace(re, `$1"${esc}"$2"${tok}"$3`));

const mdPath = path.join(ROOT, "README.md");
const md = fs.readFileSync(mdPath, "utf8").split("\n");
const c = CHAINS[key];
const link = a => `[${a}](${c.explorer}/address/${a})`;
const row = `| ${c.label} | ${link(esc)} | ${link(tok)} |`;
const head = md.findIndex(l => l.startsWith("| Network | MilestoneEscrow |"));
if (head < 0) { console.error("README Deployed table not found"); process.exit(1); }
let i = head + 2, done = false;
for (; i < md.length && md[i].startsWith("|"); i++) {
  if (md[i].startsWith(`| ${c.label} |`)) { md[i] = row; done = true; break; }
}
if (!done) md.splice(i, 0, row);
fs.writeFileSync(mdPath, md.join("\n"));
console.log(`${key}: escrow ${esc}, token ${tok} written to index.html and README.md`);
