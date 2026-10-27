// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StakeTest} from "./Stake.t.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {IStakeVault} from "../src/interfaces/IStakeVault.sol";

/// Regression tests for the final review's contract findings (C2, C4, C5, I3, I9).
contract ReviewFixesTest is StakeTest {
    // C2: the approved predicate is recorded at lock time.
    function test_lockRecordsTheApprovedPhiHash() public {
        lock("t1");
        assertEq(escrow.phiHashOf("t1"), PHI);
    }

    // C4: an Invalid verdict cannot slash stake that an open challenge holds; the ruling still settles.
    function test_invalidVerdictWaitsWhileAChallengeHoldsTheStake() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(IStakeVault.StakeHeld.selector, bytes32("t1")));
        escrow.recordVerdict("t1", IEscrow.Verdict.Invalid);
        uint256 before = usdc.balanceOf(challenger);
        vm.prank(adjudicator);
        cm.resolve(cid, true);
        assertGt(usdc.balanceOf(challenger), before, "bond back plus reward: nothing stranded");
    }

    function test_rejectedChallengeLetsThePendingVerdictLand() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        uint256 cid = cm.open("t1");
        vm.prank(adjudicator);
        cm.resolve(cid, false);
        verdict("t1", IEscrow.Verdict.Invalid);
        assertEq(vault.encumberedOf(operator), 0);
    }

    // C5: an unknown plan cannot be closed, so funding can never land in a closed, ownerless plan.
    function test_closingAnUnknownPlanReverts() public {
        bytes32 unknown = keccak256("never funded");
        vm.prank(gateway);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.PlanUnknown.selector, unknown));
        escrow.closePlan(unknown);
    }

    // I3: a drawn-but-never-run audit does not release on window expiry; only a marked not-drawn task does.
    function test_releaseExpiredNeedsTheValidatorToMarkNotDrawn() public {
        lock("t1");
        commit("t1");
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.AuditPending.selector, bytes32("t1")));
        escrow.releaseExpired("t1");
        vm.prank(validator);
        escrow.markNotDrawn("t1");
        escrow.releaseExpired("t1");
        (,,,,, IEscrow.TaskState s,,) = escrow.taskOf("t1");
        assertEq(uint8(s), uint8(IEscrow.TaskState.Released));
    }

    function test_onlyTheValidatorMarksNotDrawn() public {
        lock("t1");
        commit("t1");
        vm.prank(operator);
        vm.expectRevert();
        escrow.markNotDrawn("t1");
    }

    // I9: a rejected challenge does not close the task to further challenges.
    function test_aRejectedChallengeDoesNotBlockTheNextOne() public {
        lock("t1");
        commit("t1");
        vm.prank(challenger);
        uint256 first = cm.open("t1");
        vm.prank(adjudicator);
        cm.resolve(first, false);
        vm.prank(challenger);
        uint256 second = cm.open("t1");
        assertEq(second, first + 1);
    }
}
