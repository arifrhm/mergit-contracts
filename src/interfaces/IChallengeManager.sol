// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Bonded challenge (Should tier). Adjudicated by the platform in v0, open decision D9.
interface IChallengeManager {
    event ChallengeOpened(uint256 indexed challengeId, bytes32 indexed taskId, address challenger, uint256 bond);
    event ChallengeResolved(uint256 indexed challengeId, bytes32 indexed taskId, bool upheld);

    error NoCommitment(bytes32 taskId);
    error OutsideWindow(bytes32 taskId);
    error AlreadyChallenged(bytes32 taskId); // one open challenge per task at a time
    error UnknownChallenge(uint256 challengeId);
    error AlreadyResolved(uint256 challengeId);

    /// @notice Pulls the bond: max(1e6, amount x 1000 / 10000) USDC units
    function open(bytes32 taskId) external returns (uint256 challengeId);

    /// @notice ADJUDICATOR_ROLE
    function resolve(uint256 challengeId, bool upheld) external;

    function bondFor(bytes32 taskId) external view returns (uint256);
}
