#!/usr/bin/env bash
# Deploy to Arbitrum Sepolia. Secrets come from the environment only:
#   DEPLOYER_PRIVATE_KEY  funded Arbitrum Sepolia key (never commit it)
#   ARBISCAN_API_KEY      optional, enables --verify
#   RPC_URL               optional, default public Arbitrum Sepolia RPC
#   DEPLOY_MOCK_TOKEN     optional, "true" also deploys MockUSDG (default true here)
set -euo pipefail
cd "$(dirname "$0")"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
RPC_URL="${RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}"
export DEPLOY_MOCK_TOKEN="${DEPLOY_MOCK_TOKEN:-true}"
forge test -q
ARGS=(script script/Deploy.s.sol --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast)
[ -n "${ARBISCAN_API_KEY:-}" ] && ARGS+=(--verify --etherscan-api-key "$ARBISCAN_API_KEY")
forge "${ARGS[@]}"
echo "Paste the printed addresses into index.html (Settings)."
