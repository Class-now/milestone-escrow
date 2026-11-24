# MilestoneEscrow

Milestone-based escrow for USDG (any ERC-20) on Arbitrum. Built for the Arbitrum Open House São Paulo Online Buildathon.

**One user, one job.** Ana is a Portuguese-English translator in Recife. A US client hires her for a 600 USDG book translation in three parts. Today she either asks for money up front (and loses the client) or translates first and waits weeks for a wire that may never come. With MilestoneEscrow the client locks all 600 USDG on Arbitrum before Ana starts; each chapter she delivers releases its share to her wallet in seconds, and if they disagree about a chapter, the arbiter they both named splits only that chapter. The whole job costs a few cents in gas (table below), so even a 50-dollar milestone is worth putting on-chain.

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
./script/gas.sh         # gas per step on a local anvil chain (table below)
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

## Gas on Arbitrum

Receipt `gasUsed` for Ana's job (3 milestones, every path once), measured on a local chain with `script/gas.sh` (reproducible; needs Foundry).

| Step | Who | Gas |
|---|---|---|
| `approve` the token (once per client) | client | 46,464 |
| `createJob` with 3 milestones | client | 257,949 |
| `fund` 600 USDG | client | 73,396 |
| `approve` a milestone (pays the payee) | client | 73,996 |
| `dispute` a milestone | payee or client | 37,759 |
| `resolve` a dispute (split) | arbiter | 68,956 |
| `refund` a late milestone | client | 50,214 |
| Deploy `MilestoneEscrow` (once, shared by all jobs) | anyone | 1,299,210 |

The happy path (token approve, create, fund, three approvals) is about 600,000 gas. At Arbitrum One's 0.01 gwei L2 base-fee floor that is 0.000006 ETH, about $0.02 at $3,000/ETH. The same 600,000 gas on Ethereum mainnet at 5 gwei is 0.003 ETH, about $9, a large bite out of a 50-dollar milestone. The Arbitrum figure covers L2 execution only; Arbitrum also charges for posting the transaction data to Ethereum, which varies with L1 blob prices and is not in the table.

## Roadmap (next 3 months)

1. **Month 1: real USDG and Portuguese.** Point the page at the official USDG address on Arbitrum One, add a Portuguese and Spanish UI, and run five paid test jobs with freelancers in Brazil.
2. **Month 2: "my jobs" and silent clients.** Index events with a subgraph for a per-wallet job list, and add opt-in auto-release to the payee when the client stays silent past a review window.
3. **Month 3: arbiters and audit.** Multisig arbiters with an optional fee, an external audit, then the Arbitrum One launch, followed by the same contract on Robinhood Chain.

## Setup

```
forge install foundry-rs/forge-std --no-git
forge test
```
