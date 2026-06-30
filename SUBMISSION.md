# Privacy-Preserving Bounty Judge — Commit-Reveal (Required Track)

**Author:** solo submission
**Contract:** [`hardhat/contracts/AIJudge.sol`](hardhat/contracts/AIJudge.sol)
**Tests:** [`hardhat/test/AIJudge.t.sol`](hardhat/test/AIJudge.t.sol) — 16 passing

---

## 1. The problem we fixed

The original `AIJudge` had `submitAnswer(bountyId, answer)`, which stored the
**plaintext answer in public on-chain storage**. Anyone could read pending
submissions, copy the best one, tweak it, and submit an "improved" version
before the deadline. The contest was not fair.

**Fix:** a **commit-reveal** scheme. During submission, participants publish only
a *hash* of their answer (the commitment). The real answer is never on-chain
until everyone's submission window has closed, so there is nothing to copy.

---

## 2. Lifecycle

```
createBounty ──► submitCommitment ──► revealAnswer ──► judgeAll ──► finalizeWinner
 (owner funds)    (commit phase)       (reveal phase)    (owner)      (owner pays)
                  now < commitDL       commitDL ≤ now     now ≥        winner must
                                       < revealDL         revealDL     be revealed
```

| Phase | Function | Who | What is on-chain |
|------|----------|-----|------------------|
| Setup | `createBounty(title, rubric, commitDeadline, revealDeadline)` | owner | reward (ETH), rubric, two deadlines |
| 1. Commit | `submitCommitment(bountyId, commitment)` | participants | **only a 32-byte hash** — answer is hidden |
| 2. Reveal | `revealAnswer(bountyId, answer, salt)` | participants | plaintext answer, **verified** against the hash |
| 3. Judge | `judgeAll(bountyId, llmInput)` | owner | AI review from the LLM precompile |
| 4. Finalize | `finalizeWinner(bountyId, winnerIndex)` | owner | winner index; reward paid out |

### The commitment hash

```
commitment = keccak256(abi.encode(answer, salt, msg.sender, bountyId))
```

Why each field:
- **answer** — the thing being hidden.
- **salt** — a random secret so identical answers don't produce identical hashes
  (prevents guessing/dictionary attacks on short answers).
- **msg.sender** — binds the commitment to one wallet. If someone copies your
  commitment hash and submits it from their own wallet, they can **never reveal
  it**, because the hash includes *your* address. (Tested:
  `test_Reveal_StolenCommitmentByOther_Reverts`.)
- **bountyId** — stops a commitment from being replayed across bounties.

### Building the commitment off-chain (viem)

The reveal only succeeds if the off-chain hash matches exactly. Use `abi.encode`
(not `encodePacked`) with this exact field order:

```ts
import { encodeAbiParameters, keccak256, toHex } from "viem";

const salt = toHex(crypto.getRandomValues(new Uint8Array(32))); // keep this secret!
const commitment = keccak256(
  encodeAbiParameters(
    [{ type: "string" }, { type: "bytes32" }, { type: "address" }, { type: "uint256" }],
    [answer, salt, submitter, bountyId]
  )
);
// submitCommitment(bountyId, commitment) now; revealAnswer(bountyId, answer, salt) later.
```

There is also an on-chain helper, `computeCommitment(...)` (a `pure` function, so
it stores nothing), handy for tests and sanity checks.

---

## 3. Test plan (reveal-focused)

Run: `cd hardhat && npx hardhat test solidity`

The LLM precompile (`0x0802`) does not exist on a local chain, so `judgeAll`'s
external call is exercised with a **mock** etched onto `0x0802` (`MockLLM`) that
returns the precompile's exact ABI shape. Everything before that call (the
security logic) runs natively.

| # | Test | What it proves |
|---|------|----------------|
| 1 | `test_FullLifecycle_HappyPath` | commit → reveal → judge → finalize; winner is paid |
| 2 | `test_AnswersHiddenDuringCommitPhase` | **core property:** `getSubmission` returns an empty answer before reveal |
| 3 | `test_AnswerVisibleAfterReveal` | answer becomes readable only after a valid reveal |
| 4 | `test_Reveal_WrongSalt_Reverts` | wrong salt → `commitment mismatch` |
| 5 | `test_Reveal_WrongAnswer_Reverts` | tampered answer → `commitment mismatch` |
| 6 | `test_Reveal_StolenCommitmentByOther_Reverts` | copying someone's hash is useless (sender is bound in) |
| 7 | `test_Commit_AfterDeadline_Reverts` | no commits after `commitDeadline` |
| 8 | `test_Reveal_BeforeCommitDeadline_Reverts` | no early reveals (would leak answers) |
| 9 | `test_Reveal_AfterRevealDeadline_Reverts` | no late reveals after the window closes |
| 10 | `test_DoubleCommit_Reverts` | one commitment per wallet |
| 11 | `test_DoubleReveal_Reverts` | cannot reveal twice |
| 12 | `test_Reveal_NoCommitment_Reverts` | cannot reveal without committing first |
| 13 | `test_JudgeAll_NotOwner_Reverts` | only the bounty owner can judge |
| 14 | `test_JudgeAll_BeforeRevealDeadline_Reverts` | judging waits until reveals are closed |
| 15 | `test_Finalize_UnrevealedWinner_Reverts` | an un-revealed entry can never win |
| 16 | `test_ComputeCommitment_MatchesReveal` | the off-chain hash recipe matches on-chain verification |

**Result:** `16 passing`.

---

## 4. Architecture note

```
        PARTICIPANT (browser/wallet)                 CHAIN (AIJudge.sol)
        ----------------------------                 -------------------
 commit  answer + random salt                        bounties[id].submissions[i]:
 phase     │  keccak256(abi.encode(...))   ──tx──►     { submitter, commitment, revealed=false, answer="" }
           │  (answer & salt stay off-chain)          (only the 32-byte hash is stored)
           ▼
 reveal  send answer + salt                ──tx──►   recompute hash, compare to commitment;
 phase                                                if equal: store answer, revealed=true
                                                      else: revert
           ┌──────────────────────────────────────────────────────────────┐
 judge     │ owner builds llmInput from the now-public revealed answers     │
 phase     │ judgeAll() ──► LLM_INFERENCE_PRECOMPILE 0x0802 (runs in TEE)  │
           │           ◄── aiReview (scores / ranking) stored on-chain       │
           └──────────────────────────────────────────────────────────────┘
 finalize  owner picks winnerIndex ──► contract pays the revealed winner
```

**On-chain vs off-chain (Required track):**
- **Off-chain (until reveal):** the plaintext answer and the salt live only in the
  participant's wallet/client. Nothing readable is published during the contest.
- **On-chain during commit:** a single 32-byte commitment — irreversible, leaks
  nothing about the answer.
- **On-chain at reveal:** the plaintext answer (now safe — the window is closing
  and ranks are locked by the hash).
- **On-chain at judge:** the AI's review bytes returned by the precompile.

**Trust model of this track:** answers are *public after reveal*, which is enough
to stop copy-and-improve attacks (you can't see anyone's answer while you can
still submit). For answers that must stay secret **even during judging**, see the
Advanced track note below.

**Advanced track (not implemented here, design sketch):** encrypt each answer to
the TEE's public key off-chain; store only ciphertext (or just its CID/hash)
on-chain. The plaintext exists only inside the TEE during `judgeAll`, which
decrypts all ciphertexts and judges them in **one batched** LLM call (not one
call per answer). Ritual's FHE (`0x0807`) / encrypted-secrets primitives carry
the private inputs, so plaintext answers never appear on-chain at all.

---

## 5. Reflection

**"What should be public, what should stay hidden, and what should be decided by
AI versus by a human in a bounty system?"**

The *rules* of a bounty should be fully public — the prompt, the rubric, the
reward, the deadlines, and ultimately the winner — because transparency is what
makes the result trustworthy and verifiable by anyone. The *submissions* should
stay hidden during the contest, since visible answers let latecomers copy and
marginally improve on earlier work, which is exactly the unfairness commit-reveal
removes. After the deadline, the answers can become public so the judging is
auditable. AI is well suited to the *first-pass evaluation*: scoring and ranking
many submissions against the rubric quickly, consistently, and without the
fatigue or favoritism a human reviewer might bring. Humans should keep authority
over the *final decision and the edge cases* — confirming the AI's ranking,
handling ties, disqualifying rule-breakers, and owning subjective calls the
rubric can't fully capture. In short, AI provides scalable, consistent triage
while a human retains accountability for the outcome. The contract enforces this
split: it guarantees fairness (hidden-then-revealed answers) and records the AI
review on-chain, but `finalizeWinner` still requires a human owner to commit the
result.

---

## 6. How to run

```bash
cd hardhat
npm install                     # or pnpm install
npx hardhat compile
npx hardhat test solidity       # 16 passing

# deploy (Ritual testnet, chain 1979)
npx hardhat keystore set DEPLOYER_PRIVATE_KEY
npx hardhat ignition deploy --network ritual ignition/modules/AIJudge.ts
```
