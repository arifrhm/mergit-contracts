// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IReputationAnchor} from "./interfaces/IReputationAnchor.sol";

/// @title Validated outcomes
/// @notice Records only audited verdicts (source 0, the validator) and challenge rulings (source 1, the
///         challenge manager), with metered cost and tier, so anyone can rebuild reputation from chain data.
///         Unaudited completions are never recorded (invariant 4).
contract ReputationAnchor is AccessControl, IReputationAnchor {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    mapping(bytes32 taskId => mapping(uint8 source => bool)) public recorded;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function record(
        bytes32 taskId,
        uint256 agentId,
        bytes32 category,
        bool success,
        uint256 costMicros,
        uint8 tier,
        uint8 source
    ) external onlyRole(RECORDER_ROLE) {
        if (recorded[taskId][source]) revert DuplicateRecord(taskId, source);
        recorded[taskId][source] = true;
        emit OutcomeRecorded(taskId, agentId, category, success, costMicros, tier, source);
    }
}
