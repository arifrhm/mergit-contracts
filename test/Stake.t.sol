// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Identity} from "../src/Identity.sol";
import {ReceiptRegistry} from "../src/ReceiptRegistry.sol";
import {Escrow} from "../src/Escrow.sol";
import {StakeVault} from "../src/StakeVault.sol";
import {ChallengeManager} from "../src/ChallengeManager.sol";
import {ReputationAnchor} from "../src/ReputationAnchor.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {IStakeVault} from "../src/interfaces/IStakeVault.sol";
import {IChallengeManager} from "../src/interfaces/IChallengeManager.sol";
import {IReputationAnchor} from "../src/interfaces/IReputationAnchor.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// Stake, challenge and outcome anchoring, wired as the Deploy script wires them.
contract StakeTest is Test {
    uint64 constant WINDOW = 600;
    bytes32 constant PLAN = keccak256("plan");
    uint256 constant V = 2e6;
    uint256 constant S = 3e6; // stake per task: 1.5 x V
    bytes32 constant PHI = keccak256("approved predicate");

    MockUSDC usdc;
    Identity id;
    ReceiptRegistry reg;
    Escrow escrow;
    StakeVault vault;
    ChallengeManager cm;
    ReputationAnchor anchor;

    uint256 runtimePk = 0xA11CE;
    address requester = makeAddr("requester");
    address operator = makeAddr("operator");
    address challenger = makeAddr("challenger");
    address gateway = makeAddr("gateway");
    address validator = makeAddr("validator");
    address adjudicator = makeAddr("adjudicator");
    address reserve = makeAddr("reserve");
    uint256 agentId;

    function setUp() public {
        usdc = new MockUSDC();
        id = new Identity();
        reg = new ReceiptRegistry(id);
        escrow = new Escrow(usdc, id, WINDOW);
        vault = new StakeVault(usdc, 5);
        anchor = new ReputationAnchor();
        cm = new ChallengeManager(usdc, escrow, reg, vault, anchor, reserve);
        reg.setEscrow(address(escrow));
        escrow.setRegistry(address(reg));
        escrow.setStakeVault(address(vault));
        escrow.grantRole(escrow.GATEWAY_ROLE(), gateway);
        escrow.grantRole(escrow.VALIDATOR_ROLE(), validator);
        escrow.grantRole(escrow.CHALLENGE_ROLE(), address(cm));
        vault.grantRole(vault.ESCROW_ROLE(), address(escrow));
        vault.grantRole(vault.SLASHER_ROLE(), address(escrow));
        vault.grantRole(vault.SLASHER_ROLE(), address(cm));
        vault.grantRole(vault.HOLD_ROLE(), address(cm));
        vault.setReserve(reserve);
        anchor.grantRole(anchor.RECORDER_ROLE(), validator);
        anchor.grantRole(anchor.RECORDER_ROLE(), address(cm));
        cm.grantRole(cm.ADJUDICATOR_ROLE(), adjudicator);

        vm.prank(operator);
        agentId = id.registerAgent(vm.addr(runtimePk), "");
        for (uint256 i = 0; i < 3; i++) {
            address who = [requester, operator, challenger][i];
            usdc.mint(who, 100e6);
            vm.prank(who);
            usdc.approve(address(i == 1 ? address(vault) : i == 0 ? address(escrow) : address(cm)), type(uint256).max);
        }
        vm.prank(operator);
        vault.deposit(10e6);
        vm.prank(requester);
        escrow.fundPlan(PLAN, 20e6);
    }

    function lock(bytes32 t) internal {
        vm.prank(gateway);
        escrow.lockTask(t, PLAN, agentId, V, uint64(block.timestamp + 1800), PHI);
    }

    function commit(bytes32 t) internal {
        bytes32 structHash = keccak256(
            abi.encode(reg.RECEIPT_TYPEHASH(), t, bytes32("root"), bytes32("term"), bytes32("body"), uint256(1))
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Mergit"),
                keccak256("0"),
                block.chainid,
                address(reg)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(runtimePk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        reg.commit(t, agentId, bytes32("root"), bytes32("term"), bytes32("body"), 1, abi.encodePacked(r, s, v));
    }

    function verdict(bytes32 t, IEscrow.Verdict v) internal {
        vm.prank(validator);
        escrow.recordVerdict(t, v);
    }

    function available() internal view returns (uint256 a) {
        (,, a,) = escrow.planOf(PLAN);
    }

    // ---- StakeVault

    function test_lockEncumbersOneAndAHalfTimesV() public {
        lock("t1");
        assertEq(vault.encumberedOf(operator), S);
        assertEq(vault.freeOf(operator), 10e6 - S);
        assertEq(vault.openTasksOf(operator), 1);
    }

    function test_cannotWithdrawEncumberedStake() public {
        lock("t1");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.InsufficientFreeStake.selector, operator, 10e6 - S, 10e6));
        vault.withdraw(10e6);
        vm.prank(operator);
        vault.withdraw(10e6 - S);
    }

    function test_lockFailsWithoutEnoughFreeStake() public {
        lock("t1");
        lock("t2");
        lock("t3"); // 9 of 10 USDC encumbered
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.InsufficientFreeStake.selector, operator, 1e6, S));
        escrow.lockTask("t4", PLAN, agentId, V, uint64(block.timestamp + 1800), PHI);
    }

    function test_capOnOpenTasksPerOperator() public {
        vm.prank(operator);
        vault.deposit(90e6);
        vm.prank(requester);
        escrow.fundPlan(PLAN, 80e6);
        for (uint256 i = 0; i < 5; i++) {
            lock(bytes32(i + 1));
        }
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.TooManyOpenTasks.selector, operator, 5, 5));
        escrow.lockTask("six", PLAN, agentId, V, uint64(block.timestamp + 1800), PHI);
    }

    function test_failReleasesStakeAtOnce() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Fail);
        assertEq(vault.encumberedOf(operator), 0);
        assertEq(vault.openTasksOf(operator), 0);
    }

    function test_finalizeReleasesStakeOnlyAfterWindow() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        vm.expectRevert();
        escrow.finalize("t1");
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize("t1");
        assertEq(vault.encumberedOf(operator), 0);
    }

    function test_invalidVerdictReturnsVAndSlashesStakeToReserve() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Invalid);
        assertEq(available(), 20e6, "V back in the plan: the requester is whole");
        assertEq(usdc.balanceOf(reserve), S, "the encumbered stake is slashed to the reserve");
        assertEq(vault.encumberedOf(operator), 0);
        assertEq(vault.freeOf(operator), 10e6 - S);
    }

    // ---- ChallengeManager

    function test_challengeOnlyInsideWindow() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IChallengeManager.OutsideWindow.selector, bytes32("t1")));
        cm.open("t1");
    }

    function test_challengeNeedsACommitment() public {
        lock("t1");
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IChallengeManager.NoCommitment.selector, bytes32("t1")));
        cm.open("t1");
    }

    function test_bondIsTenPercentOfVWithAOneUsdcFloor() public {
        lock("t1");
        assertEq(cm.bondFor("t1"), 1e6, "10% of 2 USDC is below the 1 USDC floor");
    }

    function test_openChallengeHoldsStakePastTheWindow() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        vm.prank(challenger);
        cm.open("t1");
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.StakeHeld.selector, bytes32("t1")));
        escrow.finalize("t1");
    }

    function test_upheldChallengeOnReleasedTaskPaysRequesterThenChallengerThenReserve() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass); // operator already paid V
        uint256 requesterBefore = usdc.balanceOf(requester);
        uint256 challengerBefore = usdc.balanceOf(challenger);
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(adjudicator);
        cm.resolve(cid, true);
        assertEq(usdc.balanceOf(requester), requesterBefore + V, "1: requester made whole from stake");
        assertEq(usdc.balanceOf(challenger), challengerBefore + (V * 2000) / 10_000, "2: bond back plus 20% of V");
        assertEq(usdc.balanceOf(reserve), S - V - (V * 2000) / 10_000, "3: the rest of the stake to the reserve");
        assertEq(vault.encumberedOf(operator), 0);
    }

    function test_upheldChallengeOnHeldTaskReturnsVThroughEscrow() public {
        lock("t1");
        commit("t1"); // no verdict: held until the window ends
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(adjudicator);
        cm.resolve(cid, true);
        (,,,,, IEscrow.TaskState s,,) = escrow.taskOf("t1");
        assertEq(uint8(s), uint8(IEscrow.TaskState.Returned));
        assertEq(available(), 20e6, "V returned to the plan");
        assertEq(
            usdc.balanceOf(reserve), S - (V * 2000) / 10_000, "stake after the challenger's reward goes to the reserve"
        );
    }

    function test_rejectedChallengeSplitsBondAndFreesStake() public {
        lock("t1");
        commit("t1");
        verdict("t1", IEscrow.Verdict.Pass);
        uint256 operatorBefore = usdc.balanceOf(operator);
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(adjudicator);
        cm.resolve(cid, false);
        assertEq(usdc.balanceOf(operator), operatorBefore + 0.5e6, "half the bond to the operator");
        assertEq(usdc.balanceOf(reserve), 0.5e6, "half to the adjudication reserve");
        vm.warp(block.timestamp + WINDOW);
        escrow.finalize("t1");
        assertEq(vault.encumberedOf(operator), 0);
    }

    function test_onlyAdjudicatorResolvesAndOnlyOnce() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(challenger);
        vm.expectRevert();
        cm.resolve(cid, true);
        vm.prank(adjudicator);
        cm.resolve(cid, false);
        vm.prank(adjudicator);
        vm.expectRevert(abi.encodeWithSelector(IChallengeManager.AlreadyResolved.selector, cid));
        cm.resolve(cid, true);
    }

    function test_oneChallengePerTask() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        cm.open("t1");
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IChallengeManager.AlreadyChallenged.selector, bytes32("t1")));
        cm.open("t1");
    }

    // ---- ReputationAnchor

    function test_anchorRejectsNonRecorder() public {
        vm.prank(operator);
        vm.expectRevert();
        anchor.record("t1", agentId, "test-repair", true, 1, 0, 0);
    }

    function test_anchorRecordsTierAndRefusesDuplicates() public {
        vm.expectEmit(true, true, false, true);
        emit IReputationAnchor.OutcomeRecorded("t1", agentId, "test-repair", true, 41, 1, 0);
        vm.prank(validator);
        anchor.record("t1", agentId, "test-repair", true, 41, 1, 0);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(IReputationAnchor.DuplicateRecord.selector, bytes32("t1"), uint8(0)));
        anchor.record("t1", agentId, "test-repair", true, 41, 1, 0);
    }

    function test_rulingIsAnchoredAsAFailure() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.expectEmit(true, true, false, false);
        emit IReputationAnchor.OutcomeRecorded("t1", agentId, bytes32(0), false, 0, 0, 1);
        vm.prank(adjudicator);
        cm.resolve(cid, true);
    }
}
