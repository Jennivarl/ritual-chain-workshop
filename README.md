# Privacy-Preserving AI Bounty Judge

Homework submission for the Ritual AI Bounty Judge workshop — by **varl999**.

The original workshop contract stored answers in public, so people could read and
copy each other before the deadline. This repo fixes that **two ways**:

- **Required track — commit-reveal** ([`AIJudge.sol`](hardhat/contracts/AIJudge.sol)):
  participants submit a hash of their answer, reveal it after the deadline, and the
  contract verifies `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`
  before the AI batch-judges the valid reveals. Answers are hidden during the contest.
- **Advanced track — TEE-encrypted** ([`SealedAIJudge.sol`](hardhat/contracts/SealedAIJudge.sol)):
  answers are encrypted to a Ritual TEE executor's public key off-chain, so only
  ciphertext is ever on-chain — answers stay hidden **even during judging**, decrypted
  only inside the enclave. Never public.

In both, the AI **ranks** the submissions but a **human owner finalizes** the payout.

📄 **Full write-up (lifecycle, architecture, tests, reflection): [`SUBMISSION.md`](SUBMISSION.md)**

## Live on Ritual testnet (chain 1979)
| Contract | Address |
|----------|---------|
| `AIJudge` | `0x925d2b293f595b45a6b662bd52a007d8ce0d1c7c` |
| `SealedAIJudge` | `0x1846fd0533e1b63946ff7cc7933307e8bcd75aea` |

## Run the tests
```bash
cd hardhat
npm install
npx hardhat test solidity   # 29 passing
```

## Layout
```
hardhat/   Solidity contracts (AIJudge, SealedAIJudge) + forge-std tests
web/        Frontend + off-chain helpers (commitment + ECIES sealed-submission encryption)
SUBMISSION.md   The full homework write-up
```
