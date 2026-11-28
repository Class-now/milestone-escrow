#!/usr/bin/env bash
# Deploy MilestoneEscrow (and MockUSDG on testnets). Secrets come from the environment only:
#   DEPLOYER_PRIVATE_KEY  funded key on the target chain (never commit it)
#   CHAIN                 optional: arbitrum-sepolia (default) or robinhood-testnet
#   RPC_URL               optional, overrides the chain's public RPC
#   ARBISCAN_API_KEY      optional, verifies on Arbiscan (arbitrum-sepolia)
#   VERIFY                optional, "true" verifies on the Blockscout explorer (robinhood-testnet)
#   DEPLOY_MOCK_TOKEN     optional, "true" also deploys MockUSDG (default true here)
set -euo pipefail
cd "$(dirname "$0")"
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
CHAIN="${CHAIN:-arbitrum-sepolia}"
case "$CHAIN" in
  arbitrum-sepolia)  CHAIN_ID=421614; DEFAULT_RPC=https://sepolia-rollup.arbitrum.io/rpc ;;
  robinhood-testnet) CHAIN_ID=46630;  DEFAULT_RPC=https://rpc.testnet.chain.robinhood.com ;;
  *) echo "unknown CHAIN=$CHAIN (arbitrum-sepolia | robinhood-testnet)" >&2; exit 2 ;;
esac
RPC_URL="${RPC_URL:-$DEFAULT_RPC}"
got=$(cast chain-id --rpc-url "$RPC_URL")
[ "$got" = "$CHAIN_ID" ] || { echo "RPC $RPC_URL is chain $got, expected $CHAIN_ID" >&2; exit 2; }
export DEPLOY_MOCK_TOKEN="${DEPLOY_MOCK_TOKEN:-true}"
forge test -q
ARGS=(script script/Deploy.s.sol --rpc-url "$RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast)
if [ "$CHAIN" = arbitrum-sepolia ] && [ -n "${ARBISCAN_API_KEY:-}" ]; then
  ARGS+=(--verify --etherscan-api-key "$ARBISCAN_API_KEY")
elif [ "$CHAIN" = robinhood-testnet ] && [ "${VERIFY:-}" = true ]; then
  ARGS+=(--verify --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/)
fi
forge "${ARGS[@]}"
echo "Then: node script/set-deployment.mjs $CHAIN <MilestoneEscrow> <MockUSDG>  (writes index.html and README)"
