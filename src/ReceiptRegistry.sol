// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IReceiptRegistry} from "./interfaces/IReceiptRegistry.sol";
import {IIdentity} from "./interfaces/IIdentity.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";

/// @title Receipt commitments
/// @notice One commitment per task, for a task locked in Escrow, signed by the agent's runtime key. Anyone may
///         submit (the chain gateway relays); the signature is the authority. Task content never comes here.
contract ReceiptRegistry is AccessControl, EIP712, IReceiptRegistry {
    bytes32 public constant RECEIPT_TYPEHASH =
        keccak256("Receipt(bytes32 taskId,bytes32 root,bytes32 terminalHash,bytes32 bodyHash,uint256 costMicros)");

    IIdentity public immutable identity;
    address public escrow;
    mapping(bytes32 taskId => Commitment) private _commitments;

    constructor(IIdentity identity_) EIP712("Mergit", "0") {
        identity = identity_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setEscrow(address escrow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (escrow != address(0)) revert EscrowAlreadySet();
        escrow = escrow_;
    }

    function commit(
        bytes32 taskId,
        uint256 agentId,
        bytes32 root,
        bytes32 terminalHash,
        bytes32 bodyHash,
        uint256 costMicros,
        bytes calldata signature
    ) external {
        if (_commitments[taskId].committedAt != 0) revert AlreadyCommitted(taskId);
        _requireLocked(taskId, agentId);
        _requireSigner(
            agentId,
            keccak256(abi.encode(RECEIPT_TYPEHASH, taskId, root, terminalHash, bodyHash, costMicros)),
            signature
        );
        _commitments[taskId] = Commitment(agentId, root, terminalHash, bodyHash, costMicros, uint64(block.timestamp));
        emit ReceiptCommitted(taskId, agentId, root, terminalHash, bodyHash, costMicros);
    }

    function _requireLocked(bytes32 taskId, uint256 agentId) private view {
        (, uint256 taskAgent,,,, IEscrow.TaskState state,,) = IEscrow(escrow).taskOf(taskId);
        if (state != IEscrow.TaskState.Locked) revert TaskNotLocked(taskId);
        if (taskAgent != agentId) revert AgentMismatch(taskId, taskAgent, agentId);
    }

    function _requireSigner(uint256 agentId, bytes32 structHash, bytes calldata signature) private view {
        address expected = identity.runtimeKeyOf(agentId);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(_hashTypedDataV4(structHash), signature);
        if (err != ECDSA.RecoverError.NoError || recovered != expected) {
            revert BadSignature(err == ECDSA.RecoverError.NoError ? recovered : address(0), expected);
        }
    }

    function commitmentOf(bytes32 taskId) external view returns (Commitment memory) {
        return _commitments[taskId];
    }
}
