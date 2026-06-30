// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudge} from "../contracts/AIJudge.sol";

/// @dev Stand-in for the LLM inference precompile at 0x0802. Its runtime code is
///      etched onto 0x0802 so judgeAll() can be exercised without a live TEE.
///      It returns the same shape the real precompile does:
///      abi.encode(bytes simmedInput, bytes actualOutput), where actualOutput =
///      abi.encode(bool hasError, bytes completion, bytes, string err, ConvoHistory).
contract MockLLM {
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        ConvoHistory memory ch = ConvoHistory("", "", "");
        bytes memory actualOutput = abi.encode(
            false,
            bytes("WINNER: index 1"),
            bytes(""),
            "",
            ch
        );
        return abi.encode(bytes(""), actualOutput);
    }
}

contract AIJudgeTest is Test {
    AIJudge internal judge;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant REWARD = 1 ether;

    uint256 internal commitDeadline;
    uint256 internal revealDeadline;

    function setUp() public {
        judge = new AIJudge();
        vm.deal(owner, 10 ether);
        commitDeadline = block.timestamp + 1 days;
        revealDeadline = commitDeadline + 1 days;
    }

    // ----- helpers ---------------------------------------------------------

    function _createBounty() internal returns (uint256 bountyId) {
        vm.prank(owner);
        bountyId = judge.createBounty{value: REWARD}(
            "Best haiku",
            "Judge on creativity",
            commitDeadline,
            revealDeadline
        );
    }

    function _commitment(
        uint256 bountyId,
        string memory answer,
        bytes32 salt,
        address who
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, who, bountyId));
    }

    function _commit(
        uint256 bountyId,
        address who,
        string memory answer,
        bytes32 salt
    ) internal {
        vm.prank(who);
        judge.submitCommitment(bountyId, _commitment(bountyId, answer, salt, who));
    }

    // ----- happy path ------------------------------------------------------

    function test_FullLifecycle_HappyPath() public {
        uint256 id = _createBounty();

        _commit(id, alice, "alice answer", bytes32("salt-a"));
        _commit(id, bob, "bob answer", bytes32("salt-b"));

        // reveal phase
        vm.warp(commitDeadline);
        vm.prank(alice);
        judge.revealAnswer(id, "alice answer", bytes32("salt-a"));
        vm.prank(bob);
        judge.revealAnswer(id, "bob answer", bytes32("salt-b"));

        // judging phase: mock the LLM precompile
        vm.warp(revealDeadline);
        MockLLM mock = new MockLLM();
        vm.etch(address(0x0802), address(mock).code);

        vm.prank(owner);
        judge.judgeAll(id, hex"1234");

        vm.prank(owner);
        judge.finalizeWinner(id, 1); // bob

        ( , , , , , , bool judged, bool finalized, , , uint256 winnerIndex, ) = judge.getBounty(id);
        assertTrue(judged, "judged");
        assertTrue(finalized, "finalized");
        assertEq(winnerIndex, 1, "winner index");
        assertEq(bob.balance, REWARD, "winner paid");
    }

    // ----- the core security property: answers hidden in commit phase ------

    function test_AnswersHiddenDuringCommitPhase() public {
        uint256 id = _createBounty();
        _commit(id, alice, "secret answer", bytes32("salt-a"));

        (address submitter, bytes32 commitment, bool revealed, string memory answer) =
            judge.getSubmission(id, 0);

        assertEq(submitter, alice);
        assertTrue(commitment != bytes32(0), "commitment stored");
        assertFalse(revealed, "not revealed yet");
        assertEq(bytes(answer).length, 0, "answer must be empty before reveal");
    }

    function test_AnswerVisibleAfterReveal() public {
        uint256 id = _createBounty();
        _commit(id, alice, "secret answer", bytes32("salt-a"));

        vm.warp(commitDeadline);
        vm.prank(alice);
        judge.revealAnswer(id, "secret answer", bytes32("salt-a"));

        (, , bool revealed, string memory answer) = judge.getSubmission(id, 0);
        assertTrue(revealed);
        assertEq(answer, "secret answer");
    }

    // ----- reveal verification edge cases ----------------------------------

    function test_Reveal_WrongSalt_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a"));

        vm.warp(commitDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(id, "alice answer", bytes32("WRONG-salt"));
    }

    function test_Reveal_WrongAnswer_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a"));

        vm.warp(commitDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(id, "tampered answer", bytes32("salt-a"));
    }

    function test_Reveal_StolenCommitmentByOther_Reverts() public {
        // Even if bob copies alice's commitment hash, he cannot reveal it,
        // because msg.sender is part of the hash.
        uint256 id = _createBounty();
        bytes32 salt = bytes32("salt-a");
        bytes32 aliceCommit = _commitment(id, "alice answer", salt, alice);

        vm.prank(bob);
        judge.submitCommitment(id, aliceCommit); // bob front-runs with alice's hash

        vm.warp(commitDeadline);
        vm.prank(bob);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(id, "alice answer", salt);
    }

    // ----- timing windows --------------------------------------------------

    function test_Commit_AfterDeadline_Reverts() public {
        uint256 id = _createBounty();
        vm.warp(commitDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commit phase over"));
        judge.submitCommitment(id, _commitment(id, "x", bytes32("s"), alice));
    }

    function test_Reveal_BeforeCommitDeadline_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a"));

        // still in commit phase
        vm.prank(alice);
        vm.expectRevert(bytes("reveal not started"));
        judge.revealAnswer(id, "alice answer", bytes32("salt-a"));
    }

    function test_Reveal_AfterRevealDeadline_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a"));

        vm.warp(revealDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("reveal phase over"));
        judge.revealAnswer(id, "alice answer", bytes32("salt-a"));
    }

    // ----- duplicate / missing state --------------------------------------

    function test_DoubleCommit_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a"));

        vm.prank(alice);
        vm.expectRevert(bytes("already committed"));
        judge.submitCommitment(id, _commitment(id, "other", bytes32("s2"), alice));
    }

    function test_DoubleReveal_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a"));

        vm.warp(commitDeadline);
        vm.prank(alice);
        judge.revealAnswer(id, "alice answer", bytes32("salt-a"));

        vm.prank(alice);
        vm.expectRevert(bytes("already revealed"));
        judge.revealAnswer(id, "alice answer", bytes32("salt-a"));
    }

    function test_Reveal_NoCommitment_Reverts() public {
        uint256 id = _createBounty();
        vm.warp(commitDeadline);
        vm.prank(carol);
        vm.expectRevert(bytes("no commitment"));
        judge.revealAnswer(id, "anything", bytes32("s"));
    }

    // ----- judging / finalizing guards -------------------------------------

    function test_JudgeAll_NotOwner_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a"));
        vm.warp(commitDeadline);
        vm.prank(alice);
        judge.revealAnswer(id, "alice answer", bytes32("salt-a"));

        vm.warp(revealDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        judge.judgeAll(id, hex"1234");
    }

    function test_JudgeAll_BeforeRevealDeadline_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a"));
        vm.warp(commitDeadline);
        vm.prank(alice);
        judge.revealAnswer(id, "alice answer", bytes32("salt-a"));

        // reveal window still open
        vm.prank(owner);
        vm.expectRevert(bytes("reveal phase not over"));
        judge.judgeAll(id, hex"1234");
    }

    function test_Finalize_UnrevealedWinner_Reverts() public {
        uint256 id = _createBounty();
        _commit(id, alice, "alice answer", bytes32("salt-a")); // index 0, never revealed
        _commit(id, bob, "bob answer", bytes32("salt-b")); // index 1

        vm.warp(commitDeadline);
        vm.prank(bob);
        judge.revealAnswer(id, "bob answer", bytes32("salt-b"));

        vm.warp(revealDeadline);
        MockLLM mock = new MockLLM();
        vm.etch(address(0x0802), address(mock).code);
        vm.prank(owner);
        judge.judgeAll(id, hex"1234");

        // alice (index 0) never revealed -> cannot win
        vm.prank(owner);
        vm.expectRevert(bytes("winner not revealed"));
        judge.finalizeWinner(id, 0);
    }

    // ----- the helper matches what the contract verifies -------------------

    function test_ComputeCommitment_MatchesReveal() public {
        uint256 id = _createBounty();
        bytes32 salt = bytes32("salt-a");
        bytes32 fromHelper = judge.computeCommitment(id, "alice answer", salt, alice);

        vm.prank(alice);
        judge.submitCommitment(id, fromHelper);

        vm.warp(commitDeadline);
        vm.prank(alice);
        judge.revealAnswer(id, "alice answer", salt); // succeeds => helper is correct
    }
}
