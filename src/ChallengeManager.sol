// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChallengeManager} from "./interfaces/IChallengeManager.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {IReceiptRegistry} from "./interfaces/IReceiptRegistry.sol";
import {IStakeVault} from "./interfaces/IStakeVault.sol";
import {IReputationAnchor} from "./interfaces/IReputationAnchor.sol";

/// @title Bonded challenge
/// @notice Anyone may challenge a receipt inside its window by posting a bond (paper §10.3). The adjudicator
///         rules; in v0 that is the platform, which is open decision D9. Upheld: the requester is made whole,
///         the challenger gets the bond back plus a reward, the rest of the stake goes to the reserve, in that
///         order. Rejected: half the bond compensates the operator, half goes to the reserve.
///         Bond and reward rates are parameters, not measurements.
contract ChallengeManager is AccessControl, ReentrancyGuard, IChallengeManager {
    using SafeERC20 for IERC20;

    bytes32 public constant ADJUDICATOR_ROLE = keccak256("ADJUDICATOR_ROLE");
    uint256 public constant MIN_BOND = 1e6;
    uint256 public constant BOND_BPS = 1000;
    uint256 public constant REWARD_BPS = 2000;

    struct Challenge {
        bytes32 taskId;
        address challenger;
        uint256 bond;
        bool resolved;
    }

    IERC20 public immutable usdc;
    IEscrow public immutable escrow;
    IReceiptRegistry public immutable registry;
    IStakeVault public immutable vault;
    IReputationAnchor public immutable anchor;
    address public immutable reserve;

    Challenge[] internal _challenges;
    mapping(bytes32 taskId => bool) public challenged;

    constructor(
        IERC20 usdc_,
        IEscrow escrow_,
        IReceiptRegistry registry_,
        IStakeVault vault_,
        IReputationAnchor anchor_,
        address reserve_
    ) {
        (usdc, escrow, registry, vault, anchor, reserve) = (usdc_, escrow_, registry_, vault_, anchor_, reserve_);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function bondFor(bytes32 taskId) public view returns (uint256) {
        (,,, uint256 amount,,,,) = escrow.taskOf(taskId);
        uint256 b = (amount * BOND_BPS) / 10_000;
        return b < MIN_BOND ? MIN_BOND : b;
    }

    function open(bytes32 taskId) external nonReentrant returns (uint256 challengeId) {
        uint64 committedAt = registry.commitmentOf(taskId).committedAt;
        if (committedAt == 0) revert NoCommitment(taskId);
        if (!_insideWindow(taskId, committedAt)) revert OutsideWindow(taskId);
        if (challenged[taskId]) revert AlreadyChallenged(taskId);
        challenged[taskId] = true;
        uint256 bond = bondFor(taskId);
        challengeId = _challenges.length;
        _challenges.push(Challenge(taskId, msg.sender, bond, false));
        vault.hold(taskId);
        emit ChallengeOpened(challengeId, taskId, msg.sender, bond);
        usdc.safeTransferFrom(msg.sender, address(this), bond);
    }

    function resolve(uint256 challengeId, bool upheld) external nonReentrant onlyRole(ADJUDICATOR_ROLE) {
        if (challengeId >= _challenges.length) revert UnknownChallenge(challengeId);
        Challenge storage c = _challenges[challengeId];
        if (c.resolved) revert AlreadyResolved(challengeId);
        c.resolved = true;
        emit ChallengeResolved(challengeId, c.taskId, upheld);
        if (upheld) _upheld(c);
        else _rejected(c);
    }

    function _insideWindow(bytes32 taskId, uint64 committedAt) private view returns (bool) {
        (,,,,, IEscrow.TaskState state, IEscrow.Verdict verdict, uint64 settledAt) = escrow.taskOf(taskId);
        uint256 w = escrow.window();
        if (state == IEscrow.TaskState.Locked) return block.timestamp < committedAt + w;
        if (state == IEscrow.TaskState.Released && verdict == IEscrow.Verdict.Pass) {
            return block.timestamp < settledAt + w;
        }
        return false;
    }

    /// @dev Requester first (through Escrow if V is still held, else from stake), then the challenger, then the
    ///      reserve (the vault sends any remainder there).
    function _upheld(Challenge storage c) private {
        (bytes32 planId, uint256 agentId,, uint256 amount,, IEscrow.TaskState state,,) = escrow.taskOf(c.taskId);
        uint256 reward = (amount * REWARD_BPS) / 10_000;
        address[] memory to;
        uint256[] memory amounts;
        if (state == IEscrow.TaskState.Locked) {
            escrow.returnForChallenge(c.taskId);
            to = new address[](1);
            amounts = new uint256[](1);
            (to[0], amounts[0]) = (c.challenger, reward);
        } else {
            to = new address[](2);
            amounts = new uint256[](2);
            (to[0], amounts[0]) = (escrow.refundAddressOf(planId), amount);
            (to[1], amounts[1]) = (c.challenger, reward);
        }
        vault.slash(c.taskId, to, amounts);
        usdc.safeTransfer(c.challenger, c.bond);
        anchor.record(c.taskId, agentId, bytes32(0), false, 0, _tier(planId), 1);
    }

    function _rejected(Challenge storage c) private {
        (bytes32 planId, uint256 agentId, address payee,,,,,) = escrow.taskOf(c.taskId);
        vault.unhold(c.taskId);
        challenged[c.taskId] = false; // a rejected challenge must not shield the receipt from the next one
        uint256 half = c.bond / 2;
        usdc.safeTransfer(payee, half);
        usdc.safeTransfer(reserve, c.bond - half);
        anchor.record(c.taskId, agentId, bytes32(0), true, 0, _tier(planId), 1);
    }

    function _tier(bytes32 planId) private view returns (uint8) {
        (, IEscrow.Tier tier,,) = escrow.planOf(planId);
        return uint8(tier);
    }
}
