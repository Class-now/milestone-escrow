# MilestoneEscrow

Milestone-based escrow for USDG (any ERC-20) on Arbitrum. Built for the Arbitrum Open House São Paulo Online Buildathon.

## Problem

Cross-border freelancers (a large share of Latin American remote workers) face two failures: the client pays late or not at all, or the freelancer delivers and the client has no safe way to commit funds up front. Bank wires and card rails add fees and days of delay. Fully trusting a stranger on either side kills the deal.

## Users

- **Client**: locks the project budget in USDG before work starts; releases it milestone by milestone.
- **Payee (freelancer)**: sees the money is already locked, so can start work with confidence.
- **Arbiter**: a neutral third party (agreed at creation) who splits a disputed milestone.

## How it works

`src/MilestoneEscrow.sol` is one contract holding many jobs.

1. `createJob(payee, arbiter, token, amounts[], deadlines[])`: define milestones, each with an amount and a deadline.
2. `fund(id)`: client deposits the total (after an ERC-20 `approve`). Funds are now locked.
3. `approve(id, i)`: client accepts milestone `i`; its amount goes to the payee.
4. `refund(id, i)`: after the milestone deadline, if it is still unapproved and undisputed, the client reclaims it.
5. `dispute(id, i)`: client or payee escalates a pending milestone. It freezes approve and refund.
6. `resolve(id, i, toPayee)`: only the arbiter; pays `toPayee` to the payee and the remainder to the client.
7. `cancel(id)`: client cancels a job that was never funded.

Invariants (covered by fuzz tests): the escrow balance always equals the sum of Pending and Disputed milestones; every milestone settles exactly once; funds only move to the client, the payee, or per the arbiter split.

Design notes: ERC-20 calls tolerate non-standard tokens that return no value; `createJob` rejects a token address with no code (a call to it would "succeed" and the job would look funded while holding nothing), and `fund` checks the escrow balance actually grew by the full total, so a fee-on-transfer or deflationary token cannot make one job's payouts draw on other jobs' deposits; reentrancy guard on all fund-moving functions; state is updated before transfers; no admin, no upgrade, no fees. The payee can dispute before the client refunds, so a client cannot simply wait out a deadline to take the money back when work was delivered. Trade-off: either side can force arbitration, so the arbiter choice matters.

## Run

```
forge test              # 27 tests, 2 of them fuzz (512 runs each)
open index.html         # or serve statically; needs a browser wallet
```

`index.html` is a single file using ethers v6 (pinned CDN version). Enter the deployed escrow and token addresses, connect a wallet on Arbitrum Sepolia, then create, deposit, approve, refund, dispute and resolve.

## Deployed (Arbitrum Sepolia, chain 421614)

| Contract | Address |
|---|---|
| MilestoneEscrow | [0x55501CfbD04DA43110a59b792a326f2F929eFE91](https://sepolia.arbiscan.io/address/0x55501CfbD04DA43110a59b792a326f2F929eFE91) |
| MockUSDG (test token) | [0x260653ff70b7165f3c6A4911BB9BeE13b8773359](https://sepolia.arbiscan.io/address/0x260653ff70b7165f3c6A4911BB9BeE13b8773359) |

The page uses these addresses by default; any address typed in Settings overrides them.

## Deploy

Secrets come from the environment only.

```
export DEPLOYER_PRIVATE_KEY=...   # funded Arbitrum Sepolia key
export ARBISCAN_API_KEY=...       # optional, for verification
./deploy.sh                       # also deploys MockUSDG (DEPLOY_MOCK_TOKEN=true by default)
```

For real USDG, set `DEPLOY_MOCK_TOKEN=false` and paste the official USDG address into the page.

## Arbitrum and Robinhood Chain

The contract is plain Solidity 0.8.24 with no chain-specific code, so it deploys unchanged to Arbitrum One, Arbitrum Sepolia, or any Arbitrum Orbit chain including Robinhood Chain. Low fees on Arbitrum make small milestone payments (tens of dollars) economical, which is the use case on-chain escrow needs. To target another chain: change `RPC_URL` for `deploy.sh`, and the chain id and RPC in `index.html` (`CHAIN_ID`, `CHAIN_HEX`).

## Next

- Factory plus per-job events indexed by a subgraph for a "my jobs" list.
- Auto-release to the payee when the client is silent past a review window (opt-in per job).
- Arbiter reputation or multisig arbiter; fee option for arbiters.
- Native USDG integration and a Next.js/wagmi front end; Portuguese and Spanish UI.
- Audit before mainnet.

## Setup

```
forge install foundry-rs/forge-std --no-git
forge test
```
