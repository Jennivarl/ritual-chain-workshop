// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title SealedAIJudge - Ritual-native hidden submissions (Advanced track)
/// @notice Answers are encrypted to the TEE executor's public key BEFORE they
///         ever touch the chain. Only ciphertext is stored on-chain, so the
///         plaintext is hidden during the contest AND during judging — it is
///         only ever readable inside the TEE that runs the model.
///
/// How this differs from the commit-reveal `AIJudge`:
///   - Commit-reveal hides answers during submission, but they become PUBLIC at
///     reveal time.
///   - SealedAIJudge never publishes plaintext at all. There is no reveal phase;
///     the encryption itself is what keeps answers hidden, end to end.
///
/// Data flow (see SUBMISSION.md "Advanced track" for the full architecture):
///   1. createBounty   -> owner funds the bounty + sets a submit deadline.
///   2. submitSealed    -> participant encrypts their answer to the TEE pubkey
///                         (ECIES; pubkey read from Ritual's TEEServiceRegistry)
///                         and submits ONLY the ciphertext.
///   3. judgeAll        -> after the deadline, the owner forwards the stored
///                         ciphertexts to the LLM precompile as `encryptedSecrets`.
///                         The TEE decrypts them and batch-judges in ONE call.
///   4. finalizeWinner  -> owner pays the winning submitter.
contract SealedAIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    // ECIES ciphertext for a 2 KB answer is small; cap to bound storage gas.
    uint256 public constant MAX_CIPHERTEXT_BYTES = 8_192;

    uint256 public nextBountyId = 1;

    struct SealedSubmission {
        address submitter;
        bytes ciphertext; // answer encrypted to the TEE executor's public key
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submitDeadline;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        SealedSubmission[] submissions;
        mapping(address => uint256) slotOf; // 1-based; 0 == not submitted
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) private bounties;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submitDeadline
    );

    event SealedSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 ciphertextHash
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // ---------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submitDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submitDeadline > block.timestamp, "deadline in past");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submitDeadline = submitDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, submitDeadline);
    }

    // ---------------------------------------------------------------------
    // Submit (encrypted; never decrypted on-chain)
    // ---------------------------------------------------------------------

    /// @notice Submit an answer that has already been encrypted to the TEE
    ///         executor's public key off-chain. The contract stores only the
    ///         ciphertext — it can never read the plaintext, and neither can any
    ///         other participant or observer.
    /// @param ciphertext ECIES ciphertext of the answer (see web/src/lib helper).
    function submitSealed(
        uint256 bountyId,
        bytes calldata ciphertext
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submitDeadline, "submissions closed");
        require(ciphertext.length > 0, "empty ciphertext");
        require(ciphertext.length <= MAX_CIPHERTEXT_BYTES, "ciphertext too big");
        require(bounty.slotOf[msg.sender] == 0, "already submitted");
        require(
            bounty.submissions.length < MAX_SUBMISSIONS,
            "too many submissions"
        );

        bounty.submissions.push(
            SealedSubmission({submitter: msg.sender, ciphertext: ciphertext})
        );

        uint256 index = bounty.submissions.length - 1;
        bounty.slotOf[msg.sender] = index + 1;

        emit SealedSubmitted(
            bountyId,
            index,
            msg.sender,
            keccak256(ciphertext)
        );
    }

    // ---------------------------------------------------------------------
    // Judge (TEE decrypts the ciphertexts and scores them in one batch)
    // ---------------------------------------------------------------------

    /// @notice Owner forwards the encrypted submissions to the LLM precompile.
    ///         `llmInput` is built off-chain and carries the stored ciphertexts
    ///         in the precompile's `encryptedSecrets` field; the TEE decrypts
    ///         them and judges all answers in a single inference call.
    /// @dev Only callable after the submit deadline, so the set of ciphertexts
    ///      being judged is frozen.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submitDeadline, "still open");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.submissions.length > 0, "no submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    // ---------------------------------------------------------------------
    // Finalize
    // ---------------------------------------------------------------------

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submitDeadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.submitDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    /// @notice Returns the stored ciphertext for a submission. Exposing it is
    ///         safe: it is encrypted to the TEE, so only the enclave can read
    ///         the underlying answer.
    function getSealedSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, bytes memory ciphertext)
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");
        SealedSubmission storage s = bounty.submissions[index];
        return (s.submitter, s.ciphertext);
    }
}
