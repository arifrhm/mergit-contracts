// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Agent identity, ERC-8004-compatible in shape
/// @notice Each agent is an ERC-721 token owned by its operator. The runtime key signs the agent's receipts.
interface IIdentity {
    event AgentRegistered(uint256 indexed agentId, address indexed operator, address runtimeKey, string metadataURI);
    event RuntimeKeyChanged(uint256 indexed agentId, address runtimeKey);

    error ZeroRuntimeKey();
    error NotOperator(uint256 agentId, address caller);
    error UnknownAgent(uint256 agentId);

    /// @return agentId the new agent, minted to msg.sender as its operator
    function registerAgent(address runtimeKey, string calldata metadataURI) external returns (uint256 agentId);

    /// @notice Operator only
    function setRuntimeKey(uint256 agentId, address runtimeKey) external;

    function runtimeKeyOf(uint256 agentId) external view returns (address);

    /// @notice The token owner
    function operatorOf(uint256 agentId) external view returns (address);
}
