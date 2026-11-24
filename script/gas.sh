#!/usr/bin/env bash
# Reproduce the gas table in README.md: one 3-milestone job, every path once,
# on a local anvil chain. Prints the receipt gasUsed of each transaction.
# Needs forge, anvil and cast on PATH (foundryup). Run from the repo root.
set -euo pipefail
PORT=${PORT:-8547}
anvil --silent --port "$PORT" &
AP=$!
trap 'kill $AP' EXIT
sleep 2
R=http://127.0.0.1:$PORT
# anvil's well-known test keys 0 (client), 1 (payee), 2 (arbiter). Never use them on a real chain.
CK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
AK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
PAY=$(cast wallet address $PK)
ARB=$(cast wallet address $AK)
dep() { forge create --broadcast --rpc-url $R --private-key $CK "$1" --json | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["deployedTo"],d["transactionHash"])'; }
read ESC ESCTX < <(dep src/MilestoneEscrow.sol:MilestoneEscrow)
read TOK TOKTX < <(dep src/MockUSDG.sol:MockUSDG)
send() { local key=$1; shift; cast send --rpc-url $R --private-key $key --json "$@" | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["gasUsed"],16))'; }
echo "deploy MilestoneEscrow (once)  $(cast receipt --rpc-url $R $ESCTX gasUsed)"
send $CK $TOK 'faucet(uint256)' 10000000000 >/dev/null
echo "token approve (once)           $(send $CK $TOK 'approve(address,uint256)' $ESC $(cast max-uint))"
NOW=$(cast block --rpc-url $R latest --field timestamp)
D="[$((NOW+864000)),$((NOW+1728000)),$((NOW+2592000))]"
echo "createJob, 3 milestones        $(send $CK $ESC 'createJob(address,address,address,uint128[],uint64[])' $PAY $ARB $TOK '[100000000,200000000,300000000]' "$D")"
echo "fund (600 USDG)                $(send $CK $ESC 'fund(uint256)' 0)"
echo "approve milestone 0            $(send $CK $ESC 'approve(uint256,uint256)' 0 0)"
echo "dispute milestone 1 (payee)    $(send $PK $ESC 'dispute(uint256,uint256)' 0 1)"
echo "resolve milestone 1 (arbiter)  $(send $AK $ESC 'resolve(uint256,uint256,uint256)' 0 1 100000000)"
cast rpc --rpc-url $R evm_increaseTime 2600000 >/dev/null
cast rpc --rpc-url $R evm_mine >/dev/null
echo "refund milestone 2 (late)      $(send $CK $ESC 'refund(uint256,uint256)' 0 2)"
echo "payee balance (expect 200e6)   $(cast call --rpc-url $R $TOK 'balanceOf(address)(uint256)' $PAY)"
