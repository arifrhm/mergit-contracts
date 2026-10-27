# mergit-contracts

The on-chain half of [Mergit](https://github.com/mergit-io/mergit): six contracts on an Ethereum L2 that hold
commitments, amounts and verdicts, never task content. The design is in the
[HLD](https://github.com/mergit-io/mergit/blob/main/docs/HLD.md) and, upstream of it, the
[paper](https://github.com/mergit-io/mergit-research/blob/main/paper/draft-v1.md). Where they disagree, the
paper wins.

**Status:** v0, testnet only (Base Sepolia, test USDC). Nothing here has been audited, and no figure is a
measurement.

| Contract | What it does |
| --- | --- |
| **Identity** | Registers an agent as an ERC-721 token owned by its operator, with the runtime key that signs its receipts. ERC-8004-compatible in shape |
| **ReceiptRegistry** | One receipt commitment per task (Merkle root, terminal hash, body hash, metered cost), accepted only with an EIP-712 signature from the agent's runtime key |
| **Escrow** | A requester funds a plan; each task's payment is locked before execution, released on a passing verdict or after the dispute window, and returned on failure |
| **StakeVault** | Operator stake, encumbered per task, with a cap on concurrent open tasks. Slashed for a false receipt |
| **ChallengeManager** | Anyone can post a bond and challenge a receipt inside the window. In v0 the platform adjudicates (open decision D9) |
| **ReputationAnchor** | Records audited and adjudicated outcomes with their cost, so anyone can rebuild reputation |

There is no token: settlement uses USDC.

## Layout

```
src/interfaces/   the external interface of each contract; the ABIs in mergit are generated from these
src/              implementations
test/             Foundry tests, including fuzz tests
script/           deployment and seeding
deployments/      addresses per network, written by the deploy script
```

## Build and test

```bash
forge build
forge test
```

If Foundry cannot download the pinned compiler (0.8.33), use a local one: `FOUNDRY_SOLC=$(which solc) forge test`.

After changing an interface, regenerate the ABIs in `mergit` with `chain/abi/sync.sh`.

## Superseded

An earlier design (AgentPassport, ProofOfWork, ReputationRegistry, AuditTrail on Monad) is superseded and must
not come back.

## Licence

MIT.
