// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Operator stake (Should tier)
interface IStakeVault {
    event Deposited(address indexed operator, uint256 amount);
    event Withdrawn(address indexed operator, uint256 amount);
    event Encumbered(address indexed operator, bytes32 indexed taskId, uint256 amount);
    event StakeReleased(address indexed operator, bytes32 indexed taskId, uint256 amount);
    event Slashed(address indexed operator, bytes32 indexed taskId, uint256 amount);

    error InsufficientFreeStake(address operator, uint256 free, uint256 needed);
    error TooManyOpenTasks(address operator, uint256 open, uint256 max);
    error NotEncumbered(bytes32 taskId);
    error StakeHeld(bytes32 taskId);
    error ReserveAlreadySet();

    function deposit(uint256 amount) external;

    /// @notice Free stake only
    function withdraw(uint256 amount) external;

    function freeOf(address operator) external view returns (uint256);

    function encumberedOf(address operator) external view returns (uint256);

    function openTasksOf(address operator) external view returns (uint256);

    /// @notice The stake a task holds; operator is zero once released or slashed.
    function taskStake(bytes32 taskId) external view returns (address operator, uint256 amount, bool held);

    /// @notice ESCROW_ROLE
    function encumber(address operator, bytes32 taskId, uint256 amount) external;

    /// @notice ESCROW_ROLE
    function release(bytes32 taskId) external;

    /// @notice HOLD_ROLE. While held (an open challenge), the task's stake cannot be released, only slashed.
    function hold(bytes32 taskId) external;

    /// @notice HOLD_ROLE
    function unhold(bytes32 taskId) external;

    /// @notice Where slashed stake that is owed to nobody goes: the residual-loss reserve (paper §10.4).
    function reserve() external view returns (address);

    /// @notice SLASHER_ROLE. Pays `amounts` to `to` in order, out of the task's encumbered stake.
    function slash(bytes32 taskId, address[] calldata to, uint256[] calldata amounts) external returns (uint256 slashed);
}
