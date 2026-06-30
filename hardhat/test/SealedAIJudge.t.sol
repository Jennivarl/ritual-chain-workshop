// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SealedAIJudge} from "../contracts/SealedAIJudge.sol";

/// @dev Mock for the LLM inference precompile (0x0802). Etched onto 0x0802 so
///      judgeAll() can run without a live TEE. Returns the precompile's shape.
contract MockLLMSealed {
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        ConvoHistory memory ch = ConvoHistory("", "", "");
        bytes memory actualOutput = abi.encode(
            false,
            bytes('{"winnerIndex":1,"summary":"ok"}'),
            bytes(""),
            "",
            ch
        );
        return abi.encode(bytes(""), actualOutput);
    }
}

contract SealedAIJudgeTest is Test {
    SealedAIJudge internal judge;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant REWARD = 1 ether;
    uint256 internal submitDeadline;

    // stand-ins for ECIES ciphertext (the contract never decrypts these)
    bytes internal aliceCipher = hex"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
    bytes internal bobCipher = hex"b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

    function setUp() public {
        judge = new SealedAIJudge();
        vm.deal(owner, 10 ether);
        submitDeadline = block.timestamp + 1 days;
    }

    function _createBounty() internal returns (uint256 id) {
        vm.prank(owner);
        id = judge.createBounty{value: REWARD}(
            "Best gas optimization",
            "Judge on correctness then gas saved",
            submitDeadline
        );
    }

    // ----- happy path ------------------------------------------------------

    function test_FullLifecycle_EncryptedHappyPath() public {
        uint256 id = _createBounty();

        vm.prank(alice);
        judge.submitSealed(id, aliceCipher);
        vm.prank(bob);
        judge.submitSealed(id, bobCipher);

        vm.warp(submitDeadline);

        MockLLMSealed mock = new MockLLMSealed();
        vm.etch(address(0x0802), address(mock).code);

        vm.prank(owner);
        judge.judgeAll(id, hex"1234");

        vm.prank(owner);
        judge.finalizeWinner(id, 1); // bob

        (, , , , , bool judged, bool finalized, uint256 count, uint256 winnerIndex, ) =
            judge.getBounty(id);
        assertTrue(judged);
        assertTrue(finalized);
        assertEq(count, 2);
        assertEq(winnerIndex, 1);
        assertEq(bob.balance, REWARD, "winner paid");
    }

    // ----- core property: only ciphertext is ever stored -------------------

    function test_OnlyCiphertextStored_NoPlaintextPath() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitSealed(id, aliceCipher);

        (address submitter, bytes memory stored) = judge.getSealedSubmission(id, 0);
        assertEq(submitter, alice);
        // The contract stores exactly the ciphertext it was given and offers no
        // function that returns a decrypted answer. Plaintext lives only in the
        // participant's client (pre-encryption) and inside the TEE (at judging).
        assertEq(keccak256(stored), keccak256(aliceCipher));
    }

    // ----- guards ----------------------------------------------------------

    function test_Submit_AfterDeadline_Reverts() public {
        uint256 id = _createBounty();
        vm.warp(submitDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("submissions closed"));
        judge.submitSealed(id, aliceCipher);
    }

    function test_DoubleSubmit_Reverts() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitSealed(id, aliceCipher);
        vm.prank(alice);
        vm.expectRevert(bytes("already submitted"));
        judge.submitSealed(id, bobCipher);
    }

    function test_EmptyCiphertext_Reverts() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        vm.expectRevert(bytes("empty ciphertext"));
        judge.submitSealed(id, hex"");
    }

    function test_CiphertextTooBig_Reverts() public {
        uint256 id = _createBounty();
        bytes memory big = new bytes(8_193); // MAX_CIPHERTEXT_BYTES + 1
        vm.prank(alice);
        vm.expectRevert(bytes("ciphertext too big"));
        judge.submitSealed(id, big);
    }

    function test_JudgeAll_BeforeDeadline_Reverts() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitSealed(id, aliceCipher);
        vm.prank(owner);
        vm.expectRevert(bytes("still open"));
        judge.judgeAll(id, hex"1234");
    }

    function test_JudgeAll_NotOwner_Reverts() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitSealed(id, aliceCipher);
        vm.warp(submitDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        judge.judgeAll(id, hex"1234");
    }

    function test_JudgeAll_NoSubmissions_Reverts() public {
        uint256 id = _createBounty();
        vm.warp(submitDeadline);
        vm.prank(owner);
        vm.expectRevert(bytes("no submissions"));
        judge.judgeAll(id, hex"1234");
    }

    function test_Finalize_BeforeJudged_Reverts() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        judge.submitSealed(id, aliceCipher);
        vm.warp(submitDeadline);
        vm.prank(owner);
        vm.expectRevert(bytes("not judged yet"));
        judge.finalizeWinner(id, 0);
    }
}
