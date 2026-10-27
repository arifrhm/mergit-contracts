// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEscrow} from "../../src/interfaces/IEscrow.sol";

/// Answers taskOf() only, so ReceiptRegistry can be tested without the real Escrow.
contract MockEscrowTasks {
    mapping(bytes32 => uint256) public agentOf;
    mapping(bytes32 => IEscrow.TaskState) public stateOf;

    function setTask(bytes32 taskId, uint256 agentId, IEscrow.TaskState state) external {
        agentOf[taskId] = agentId;
        stateOf[taskId] = state;
    }

    function taskOf(bytes32 taskId)
        external
        view
        returns (bytes32, uint256, address, uint256, uint64, IEscrow.TaskState, IEscrow.Verdict, uint64)
    {
        return (bytes32(0), agentOf[taskId], address(0), 0, 0, stateOf[taskId], IEscrow.Verdict.None, 0);
    }
}
