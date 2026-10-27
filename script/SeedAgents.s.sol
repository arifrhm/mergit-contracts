// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Identity} from "../src/Identity.sol";
import {StakeVault} from "../src/StakeVault.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// Registers the platform's agents. Each operator registers its own agent with its own key, so the operator
/// owns the identity and receives the payouts. Writes deployments/agents-<DEPLOYMENT_NAME>.json.
///
/// Env: DEPLOYMENT_NAME (default "base-sepolia"); AGENT_COUNT; for i in 0..AGENT_COUNT-1:
///      OPERATOR_KEY_i (private key), RUNTIME_ADDR_i (address of the agent's receipt-signing key),
///      AGENT_NAME_i, METADATA_URI_i (optional), STAKE_UNITS_i (USDC base units the operator stakes; optional; on
///      Anvil the operator is minted that much mock USDC first; on a testnet it must already hold it).
contract SeedAgents is Script {
    function run() external {
        string memory name = vm.envOr("DEPLOYMENT_NAME", string("base-sepolia"));
        string memory deployment = vm.readFile(string.concat("deployments/", name, ".json"));
        Identity identity = Identity(vm.parseJsonAddress(deployment, ".identity"));
        StakeVault vault = StakeVault(vm.parseJsonAddress(deployment, ".stake_vault"));
        address usdc = vm.parseJsonAddress(deployment, ".usdc");
        uint256 count = vm.envUint("AGENT_COUNT");

        string memory list = "agents";
        string memory items = "[";
        for (uint256 i = 0; i < count; i++) {
            string memory n = vm.toString(i);
            uint256 operatorKey = vm.envUint(string.concat("OPERATOR_KEY_", n));
            address runtime = vm.envAddress(string.concat("RUNTIME_ADDR_", n));
            string memory agentName = vm.envString(string.concat("AGENT_NAME_", n));
            string memory uri = vm.envOr(string.concat("METADATA_URI_", n), string(""));

            vm.broadcast(operatorKey);
            uint256 agentId = identity.registerAgent(runtime, uri);
            stake(vault, usdc, operatorKey, vm.envOr(string.concat("STAKE_UNITS_", n), uint256(0)));

            string memory obj = string.concat("agent", n);
            vm.serializeString(obj, "agent_id", vm.toString(agentId));
            vm.serializeString(obj, "name", agentName);
            vm.serializeAddress(obj, "operator", vm.addr(operatorKey));
            vm.serializeAddress(obj, "runtime_key", runtime);
            string memory item = vm.serializeString(obj, "metadata_uri", uri);
            items = string.concat(items, i == 0 ? "" : ",", item);
        }
        items = string.concat(items, "]");
        string memory json = vm.serializeString(list, "network", name);
        json = string.concat('{"agents":', items, ',"network":"', name, '"}');
        vm.writeJson(json, string.concat("deployments/agents-", name, ".json"));
    }

    function stake(StakeVault vault, address usdc, uint256 operatorKey, uint256 amount) internal {
        if (amount == 0) return;
        vm.startBroadcast(operatorKey);
        if (block.chainid == 31337) MockUSDC(usdc).mint(vm.addr(operatorKey), amount);
        MockUSDC(usdc).approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopBroadcast();
    }
}
