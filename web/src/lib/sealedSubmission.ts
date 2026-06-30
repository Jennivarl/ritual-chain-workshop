/**
 * ============================================================================
 *  Sealed submission encryption (Advanced track)
 * ============================================================================
 *
 * Encrypts a participant's answer to the TEE executor's public key BEFORE it is
 * sent on-chain, so `SealedAIJudge.submitSealed(bountyId, ciphertext)` only ever
 * stores ciphertext. The plaintext exists in two places only:
 *   1. here, in the participant's browser, for the moment before encryption;
 *   2. inside the TEE, at judging time, after the precompile decrypts it.
 * It is never on-chain and never visible to other participants.
 *
 * This mirrors exactly how Ritual's own sovereign-agent tooling ships secrets to
 * an executor: read the executor's public key from the on-chain
 * TEEServiceRegistry (capability 0 = LLM inference), then ECIES-encrypt to it.
 *
 * ⚠️ Config note: the ECIES parameters MUST match what the executor expects
 *    (symmetric nonce length 12, secp256k1, HKDF-SHA256). Ritual's reference
 *    encryptor uses `symmetric_nonce_length = 12`; we set the same here. If the
 *    executor rejects a ciphertext, this is the first thing to check.
 *
 * Dependencies: `npm i eciesjs viem`
 */

import { encrypt, ECIES_CONFIG } from "eciesjs";
import {
  bytesToHex,
  createPublicClient,
  http,
  type Address,
  type Hex,
} from "viem";

// Match Ritual's executor-side ECIES configuration.
ECIES_CONFIG.symmetricNonceLength = 12;

/** Ritual testnet (chain 1979). */
export const RITUAL_RPC = "https://rpc.ritualfoundation.org";

/** TEEServiceRegistry — same registry the sovereign-agent flow reads. */
export const TEE_REGISTRY: Address =
  "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F";

/** capability id 0 == LLM inference executors. */
const LLM_CAPABILITY = 0;

const registryAbi = [
  {
    type: "function",
    name: "getServicesByCapability",
    stateMutability: "view",
    inputs: [
      { name: "c", type: "uint8" },
      { name: "v", type: "bool" },
    ],
    outputs: [
      {
        type: "tuple[]",
        components: [
          {
            name: "node",
            type: "tuple",
            components: [
              { name: "paymentAddress", type: "address" },
              { name: "teeAddress", type: "address" },
              { name: "teeType", type: "uint8" },
              { name: "publicKey", type: "bytes" },
              { name: "endpoint", type: "string" },
              { name: "certPubKeyHash", type: "bytes32" },
              { name: "capability", type: "uint8" },
            ],
          },
          { name: "isValid", type: "bool" },
          { name: "workloadId", type: "bytes32" },
        ],
      },
    ],
  },
] as const;

export type Executor = {
  /** teeAddress — also the executor address passed into the judge LLM request. */
  address: Address;
  /** ECIES public key to encrypt answers to. */
  publicKey: Hex;
};

/**
 * Read the first valid LLM executor (its address + public key) from the
 * on-chain TEEServiceRegistry. This is the key participants encrypt to and the
 * executor the owner targets in `buildJudgeAllLlmInput`.
 */
export async function getLlmExecutor(): Promise<Executor> {
  const client = createPublicClient({ transport: http(RITUAL_RPC) });

  const services = (await client.readContract({
    address: TEE_REGISTRY,
    abi: registryAbi,
    functionName: "getServicesByCapability",
    args: [LLM_CAPABILITY, true],
  })) as ReadonlyArray<{
    node: { teeAddress: Address; publicKey: Hex };
    isValid: boolean;
  }>;

  if (!services.length) throw new Error("no valid LLM executors in registry");

  const node = services[0].node;
  return { address: node.teeAddress, publicKey: node.publicKey };
}

/**
 * Encrypt an answer to the executor's public key. Returns the ciphertext as a
 * 0x-hex `bytes` value ready to pass to `submitSealed(bountyId, ciphertext)`.
 *
 * The plaintext is discarded after this call returns; the caller keeps nothing
 * on-chain but the ciphertext.
 */
export function encryptAnswer(executor: Executor, answer: string): Hex {
  // eciesjs accepts the public key as a hex string (with or without 0x).
  const pubKeyHex = executor.publicKey.replace(/^0x/, "");
  const ciphertext = encrypt(pubKeyHex, new TextEncoder().encode(answer));
  return bytesToHex(ciphertext);
}

/**
 * Convenience: fetch the executor and encrypt in one step.
 *
 *   const { executor, ciphertext } = await sealAnswer("my secret answer");
 *   await writeContract({ ... functionName: "submitSealed", args: [bountyId, ciphertext] });
 */
export async function sealAnswer(
  answer: string,
): Promise<{ executor: Executor; ciphertext: Hex }> {
  const executor = await getLlmExecutor();
  return { executor, ciphertext: encryptAnswer(executor, answer) };
}
