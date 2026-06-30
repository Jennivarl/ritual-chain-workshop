// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

/// @title AIJudge - commit-reveal bounty with AI judging
/// @notice Answers stay hidden until the reveal phase, so participants cannot
///         copy each other during the submission window.
///
/// Lifecycle:
///   1. createBounty       -> owner funds a bounty with two deadlines.
///   2. submitCommitment   -> participants post ONLY a hash of their answer
///                            (commit phase: now < commitDeadline).
///   3. revealAnswer       -> after commitDeadline, participants reveal the
///                            plaintext answer + salt; the contract checks it
///                            matches the hash they committed to.
///   4. judgeAll           -> after revealDeadline, owner sends the revealed
///                            answers to the LLM precompile for batch judging.
///   5. finalizeWinner     -> owner pays the winning (revealed) submitter.
contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    /// @dev One entry per participant. `answer` stays empty until revealed,
    ///      so the plaintext never touches storage during the commit phase.
    struct Submission {
        address submitter;
        bytes32 commitment;
        bool revealed;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 commitDeadline; // commits accepted while now < commitDeadline
        uint256 revealDeadline; // reveals accepted while commitDeadline <= now < revealDeadline
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        uint256 revealedCount;
        Submission[] submissions;
        // 1-based index of a submitter's slot (0 == has not committed)
        mapping(address => uint256) slotOf;
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
        uint256 commitDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
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
    // Bounty setup
    // ---------------------------------------------------------------------

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 commitDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(commitDeadline > block.timestamp, "commit deadline in past");
        require(
            revealDeadline > commitDeadline,
            "reveal must end after commit"
        );

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.commitDeadline = commitDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            commitDeadline,
            revealDeadline
        );
    }

    // ---------------------------------------------------------------------
    // Phase 1: commit (answers hidden)
    // ---------------------------------------------------------------------

    /// @notice Submit only a commitment hash. The plaintext answer is NOT sent
    ///         on-chain here, so nobody can read or copy it.
    /// @dev The commitment must equal
    ///      keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)).
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.commitDeadline, "commit phase over");
        require(commitment != bytes32(0), "empty commitment");
        require(bounty.slotOf[msg.sender] == 0, "already committed");
        require(
            bounty.submissions.length < MAX_SUBMISSIONS,
            "too many submissions"
        );

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                revealed: false,
                answer: ""
            })
        );

        uint256 index = bounty.submissions.length - 1;
        bounty.slotOf[msg.sender] = index + 1; // store as 1-based

        emit CommitmentSubmitted(bountyId, index, msg.sender, commitment);
    }

    // ---------------------------------------------------------------------
    // Phase 2: reveal (verify the hidden answer matches the commitment)
    // ---------------------------------------------------------------------

    /// @notice Reveal the answer + salt. The contract recomputes the hash and
    ///         checks it against the commitment from phase 1.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.commitDeadline,
            "reveal not started"
        );
        require(block.timestamp < bounty.revealDeadline, "reveal phase over");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 slot = bounty.slotOf[msg.sender];
        require(slot != 0, "no commitment");

        Submission storage submission = bounty.submissions[slot - 1];
        require(!submission.revealed, "already revealed");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(expected == submission.commitment, "commitment mismatch");

        submission.revealed = true;
        submission.answer = answer;
        bounty.revealedCount += 1;

        emit AnswerRevealed(bountyId, slot - 1, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Phase 3: AI judging (only revealed answers are eligible)
    // ---------------------------------------------------------------------

    /// @notice Owner sends the revealed answers to the LLM precompile for batch
    ///         judging. `llmInput` is the off-chain-built prompt payload.
    /// @dev Only callable once the reveal window has closed, so no late reveals
    ///      can slip in after judging starts.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.revealDeadline,
            "reveal phase not over"
        );
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealedCount > 0, "no revealed answers");

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
    // Phase 4: finalize + pay the winner
    // ---------------------------------------------------------------------

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");
        require(
            bounty.submissions[winnerIndex].revealed,
            "winner not revealed"
        );

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
            uint256 commitDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 revealedCount,
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
            bounty.commitDeadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            bounty.revealedCount,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    /// @notice Returns a submission. `answer` is empty until that participant
    ///         has revealed, which is exactly how answers stay hidden.
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            bool revealed,
            string memory answer
        )
    {
        Bounty storage bounty = bounties[bountyId];

        require(index < bounty.submissions.length, "invalid index");

        Submission storage submission = bounty.submissions[index];

        return (
            submission.submitter,
            submission.commitment,
            submission.revealed,
            submission.answer
        );
    }

    /// @notice Off-chain helper: compute the commitment for a given answer/salt.
    ///         Pure, so it never stores anything on-chain.
    function computeCommitment(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt,
        address submitter
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }
}
