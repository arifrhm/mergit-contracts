// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Identity} from "../src/Identity.sol";
import {ReceiptRegistry} from "../src/ReceiptRegistry.sol";
import {IReceiptRegistry} from "../src/interfaces/IReceiptRegistry.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {MockEscrowTasks} from "./mocks/MockEscrowTasks.sol";

contract ReceiptRegistryTest is Test {
    bytes32 constant TYPEHASH =
        keccak256("Receipt(bytes32 taskId,bytes32 root,bytes32 terminalHash,bytes32 bodyHash,uint256 costMicros)");

    Identity id;
    ReceiptRegistry reg;
    MockEscrowTasks escrow;
    uint256 runtimePk = 0xA11CE;
    address operator = makeAddr("operator");
    uint256 agentId;
    bytes32 taskId = keccak256("task");

    function setUp() public {
        id = new Identity();
        reg = new ReceiptRegistry(id);
        escrow = new MockEscrowTasks();
        reg.setEscrow(address(escrow));
        vm.prank(operator);
        agentId = id.registerAgent(vm.addr(runtimePk), "");
        escrow.setTask(taskId, agentId, IEscrow.TaskState.Locked);
    }

    function digest(
        address registry,
        uint256 chainId,
        bytes32 t,
        bytes32 root,
        bytes32 term,
        bytes32 body,
        uint256 cost
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Mergit"),
                keccak256("0"),
                chainId,
                registry
            )
        );
        return
            keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(TYPEHASH, t, root, term, body, cost))));
    }

    function sign(uint256 pk, bytes32 t) internal view returns (bytes memory) {
        bytes32 d = digest(address(reg), block.chainid, t, bytes32("root"), bytes32("term"), bytes32("body"), 7);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    /// Pins Solidity's EIP-712 encoding to the Rust signer: spec/vectors/valid_three_steps.json, signed by the
    /// Rust crate for chain 84532 and registry 0x…01. Regenerating the vectors with the same inputs reproduces
    /// these bytes (deterministic signing); if this fails, Rust and Solidity disagree on the digest.
    function test_digestMatchesRustVector() public pure {
        bytes32 d = digest(
            address(1),
            84532,
            0x27cccb31d127fb312759aa19b3301504bb4adeb169f66cae4014b116a67158a1,
            0x86654afdeba6c74f8b308e636bc1da79d445d1c9130b53ac6306a9e132d9e71d,
            0xaf5d683fbbf2143cde898edef321aec0ca590ee89e6b9af9af8bb46228e0af11,
            0xb9a78923eaf47135906e5039d46de7b384a2bd229e730a055a09b14f3e8dd552,
            2400
        );
        bytes32 r = 0x6469867c94a5eb37596b6b222b82b5f0145a6dfc493916be21d4f5168e30ab9a;
        bytes32 s = 0x523d35f6747c00d08efbbbd83b14e675666de05c635d1db9d124ad3959054148;
        uint8 v = 0x1c;
        assertEq(ecrecover(d, v, r, s), 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    }

    function test_commitAcceptsSignatureFromRuntimeKey() public {
        vm.expectEmit(true, true, false, true);
        emit IReceiptRegistry.ReceiptCommitted(taskId, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 7);
        reg.commit(taskId, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 7, sign(runtimePk, taskId));
        IReceiptRegistry.Commitment memory c = reg.commitmentOf(taskId);
        assertEq(c.root, bytes32("root"));
        assertEq(c.agentId, agentId);
        assertEq(c.committedAt, uint64(block.timestamp));
    }

    function test_commitRejectsWrongSigner() public {
        bytes memory sig = sign(0xBAD, taskId);
        vm.expectRevert(
            abi.encodeWithSelector(IReceiptRegistry.BadSignature.selector, vm.addr(0xBAD), vm.addr(runtimePk))
        );
        reg.commit(taskId, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 7, sig);
    }

    function test_commitRejectsMalformedSignature() public {
        vm.expectRevert(abi.encodeWithSelector(IReceiptRegistry.BadSignature.selector, address(0), vm.addr(runtimePk)));
        reg.commit(taskId, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 7, hex"1234");
    }

    function test_commitRejectsEditedFieldUnderValidSignature() public {
        bytes memory sig = sign(runtimePk, taskId);
        vm.expectRevert();
        reg.commit(taskId, agentId, bytes32("other root"), bytes32("term"), bytes32("body"), 7, sig);
    }

    function test_commitRejectsSecondCommitmentForTask() public {
        reg.commit(taskId, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 7, sign(runtimePk, taskId));
        bytes memory sig = sign(runtimePk, taskId);
        vm.expectRevert(abi.encodeWithSelector(IReceiptRegistry.AlreadyCommitted.selector, taskId));
        reg.commit(taskId, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 7, sig);
    }

    function test_commitRejectsTaskNotLockedInEscrow() public {
        bytes32 other = keccak256("never locked");
        bytes memory sig = sign(runtimePk, other);
        vm.expectRevert(abi.encodeWithSelector(IReceiptRegistry.TaskNotLocked.selector, other));
        reg.commit(other, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 7, sig);
    }

    function test_commitRejectsAgentMismatchWithEscrowTask() public {
        vm.prank(operator);
        uint256 otherAgent = id.registerAgent(vm.addr(runtimePk), "");
        bytes memory sig = sign(runtimePk, taskId);
        vm.expectRevert(abi.encodeWithSelector(IReceiptRegistry.AgentMismatch.selector, taskId, agentId, otherAgent));
        reg.commit(taskId, otherAgent, bytes32("root"), bytes32("term"), bytes32("body"), 7, sig);
    }

    function test_setEscrowOnlyOnceAndOnlyAdmin() public {
        vm.expectRevert(IReceiptRegistry.EscrowAlreadySet.selector);
        reg.setEscrow(address(0xBEEF));
        ReceiptRegistry fresh = new ReceiptRegistry(id);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        fresh.setEscrow(address(0xBEEF));
    }
}
