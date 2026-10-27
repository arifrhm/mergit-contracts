// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStakeVault} from "./interfaces/IStakeVault.sol";

/// @title Operator stake
/// @notice Stake is what prices an identity and what clawback can reach (paper §7.2, §10.4). Each open task
///         encumbers some of an operator's stake until its window ends; an operator may hold at most
///         `maxOpenTasks` unresolved tasks at once (the concurrency cap, §7.5).
contract StakeVault is AccessControl, ReentrancyGuard, IStakeVault {
    using SafeERC20 for IERC20;

    bytes32 public constant ESCROW_ROLE = keccak256("ESCROW_ROLE");
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant HOLD_ROLE = keccak256("HOLD_ROLE");

    struct TaskStake {
        address operator;
        uint256 amount;
        bool held;
    }

    IERC20 public immutable usdc;
    uint256 public immutable maxOpenTasks;
    address public reserve;

    mapping(address operator => uint256) public stakeOf;
    mapping(address operator => uint256) public encumberedOf;
    mapping(address operator => uint256) public openTasksOf;
    mapping(bytes32 taskId => TaskStake) public taskStake;

    constructor(IERC20 usdc_, uint256 maxOpenTasks_) {
        usdc = usdc_;
        maxOpenTasks = maxOpenTasks_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setReserve(address reserve_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (reserve != address(0)) revert ReserveAlreadySet();
        reserve = reserve_;
    }

    function deposit(uint256 amount) external nonReentrant {
        stakeOf[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        uint256 free = freeOf(msg.sender);
        if (free < amount) revert InsufficientFreeStake(msg.sender, free, amount);
        stakeOf[msg.sender] -= amount;
        emit Withdrawn(msg.sender, amount);
        usdc.safeTransfer(msg.sender, amount);
    }

    function freeOf(address operator) public view returns (uint256) {
        return stakeOf[operator] - encumberedOf[operator];
    }

    function encumber(address operator, bytes32 taskId, uint256 amount) external onlyRole(ESCROW_ROLE) {
        uint256 free = freeOf(operator);
        if (free < amount) revert InsufficientFreeStake(operator, free, amount);
        if (openTasksOf[operator] >= maxOpenTasks) {
            revert TooManyOpenTasks(operator, openTasksOf[operator], maxOpenTasks);
        }
        encumberedOf[operator] += amount;
        openTasksOf[operator] += 1;
        taskStake[taskId] = TaskStake(operator, amount, false);
        emit Encumbered(operator, taskId, amount);
    }

    function release(bytes32 taskId) external onlyRole(ESCROW_ROLE) {
        TaskStake memory t = _open(taskId);
        if (t.held) revert StakeHeld(taskId);
        _close(taskId, t);
        emit StakeReleased(t.operator, taskId, t.amount);
    }

    function hold(bytes32 taskId) external onlyRole(HOLD_ROLE) {
        _open(taskId);
        taskStake[taskId].held = true;
    }

    function unhold(bytes32 taskId) external onlyRole(HOLD_ROLE) {
        _open(taskId);
        taskStake[taskId].held = false;
    }

    /// @dev Pays each recipient up to its amount, in order, until the task's stake runs out.
    function slash(bytes32 taskId, address[] calldata to, uint256[] calldata amounts)
        external
        nonReentrant
        onlyRole(SLASHER_ROLE)
        returns (uint256 slashed)
    {
        TaskStake memory t = _open(taskId);
        // While a challenge holds the stake, only the challenge's own ruling may slash it.
        if (t.held && !hasRole(HOLD_ROLE, msg.sender)) revert StakeHeld(taskId);
        _close(taskId, t);
        stakeOf[t.operator] -= t.amount;
        uint256 left = t.amount;
        for (uint256 i = 0; i < to.length && left > 0; i++) {
            uint256 pay = amounts[i] < left ? amounts[i] : left;
            left -= pay;
            if (pay > 0) usdc.safeTransfer(to[i], pay);
        }
        slashed = t.amount - left;
        // Anything not owed to a named recipient is not returned to the operator: it goes to the reserve.
        if (left > 0) usdc.safeTransfer(reserve, left);
        emit Slashed(t.operator, taskId, t.amount);
    }

    function _open(bytes32 taskId) private view returns (TaskStake memory t) {
        t = taskStake[taskId];
        if (t.operator == address(0)) revert NotEncumbered(taskId);
    }

    function _close(bytes32 taskId, TaskStake memory t) private {
        encumberedOf[t.operator] -= t.amount;
        openTasksOf[t.operator] -= 1;
        delete taskStake[taskId];
    }
}
