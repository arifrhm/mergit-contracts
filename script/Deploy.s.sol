// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Identity} from "../src/Identity.sol";
import {Escrow} from "../src/Escrow.sol";
import {ReceiptRegistry} from "../src/ReceiptRegistry.sol";
import {StakeVault} from "../src/StakeVault.sol";
import {ChallengeManager} from "../src/ChallengeManager.sol";
import {ReputationAnchor} from "../src/ReputationAnchor.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// Deploys and wires the six contracts, grants the platform roles, and writes deployments/<DEPLOYMENT_NAME>.json.
///
/// Env: GATEWAY_ADDR, VALIDATOR_ADDR, TREASURY_ADDR, ADJUDICATOR_ADDR (required);
///      USDC (required except on Anvil, where a mock is deployed and the treasury gets mock USDC);
///      RESERVE_ADDR (residual-loss reserve; default: the treasury); WINDOW_SECONDS (default 600);
///      MAX_OPEN_TASKS (per operator; default 5); DEPLOYMENT_NAME (default "base-sepolia").
contract Deploy is Script {
    struct Roles {
        address gateway;
        address validator;
        address treasury;
        address adjudicator;
        address reserve;
    }

    struct Deployed {
        address usdc;
        Identity identity;
        Escrow escrow;
        ReceiptRegistry registry;
        StakeVault vault;
        ChallengeManager challenges;
        ReputationAnchor anchor;
    }

    function run() external {
        Roles memory r = Roles(
            vm.envAddress("GATEWAY_ADDR"),
            vm.envAddress("VALIDATOR_ADDR"),
            vm.envAddress("TREASURY_ADDR"),
            vm.envAddress("ADJUDICATOR_ADDR"),
            vm.envOr("RESERVE_ADDR", vm.envAddress("TREASURY_ADDR"))
        );
        uint64 window = uint64(vm.envOr("WINDOW_SECONDS", uint256(600)));
        uint256 deployBlock = block.number;

        vm.startBroadcast();
        Deployed memory d = deploy(r, window);
        wire(d, r);
        vm.stopBroadcast();

        write(d, r, window, deployBlock);
    }

    function deploy(Roles memory r, uint64 window) internal returns (Deployed memory d) {
        d.usdc = vm.envOr("USDC", address(0));
        if (d.usdc == address(0)) {
            require(block.chainid == 31337, "USDC is required outside Anvil");
            MockUSDC mock = new MockUSDC();
            mock.mint(r.treasury, 1_000_000e6); // local free credits
            d.usdc = address(mock);
        }
        d.identity = new Identity();
        d.escrow = new Escrow(IERC20(d.usdc), d.identity, window);
        d.registry = new ReceiptRegistry(d.identity);
        d.vault = new StakeVault(IERC20(d.usdc), vm.envOr("MAX_OPEN_TASKS", uint256(5)));
        d.anchor = new ReputationAnchor();
        d.challenges = new ChallengeManager(IERC20(d.usdc), d.escrow, d.registry, d.vault, d.anchor, r.reserve);
    }

    function wire(Deployed memory d, Roles memory r) internal {
        d.registry.setEscrow(address(d.escrow));
        d.escrow.setRegistry(address(d.registry));
        d.escrow.setStakeVault(address(d.vault));
        d.vault.setReserve(r.reserve);

        d.escrow.grantRole(d.escrow.GATEWAY_ROLE(), r.gateway);
        d.escrow.grantRole(d.escrow.VALIDATOR_ROLE(), r.validator);
        d.escrow.grantRole(d.escrow.TREASURY_ROLE(), r.treasury);
        d.escrow.grantRole(d.escrow.CHALLENGE_ROLE(), address(d.challenges));
        d.vault.grantRole(d.vault.ESCROW_ROLE(), address(d.escrow));
        d.vault.grantRole(d.vault.SLASHER_ROLE(), address(d.escrow));
        d.vault.grantRole(d.vault.SLASHER_ROLE(), address(d.challenges));
        d.vault.grantRole(d.vault.HOLD_ROLE(), address(d.challenges));
        d.anchor.grantRole(d.anchor.RECORDER_ROLE(), r.validator);
        d.anchor.grantRole(d.anchor.RECORDER_ROLE(), address(d.challenges));
        d.challenges.grantRole(d.challenges.ADJUDICATOR_ROLE(), r.adjudicator);
    }

    function write(Deployed memory d, Roles memory r, uint64 window, uint256 deployBlock) internal {
        string memory roles = "roles";
        vm.serializeAddress(roles, "gateway", r.gateway);
        vm.serializeAddress(roles, "validator", r.validator);
        vm.serializeAddress(roles, "treasury", r.treasury);
        vm.serializeAddress(roles, "reserve", r.reserve);
        string memory rolesJson = vm.serializeAddress(roles, "adjudicator", r.adjudicator);

        string memory k = "deployment";
        vm.serializeUint(k, "chain_id", block.chainid);
        vm.serializeUint(k, "deploy_block", deployBlock);
        vm.serializeUint(k, "window_seconds", window);
        vm.serializeAddress(k, "usdc", d.usdc);
        vm.serializeAddress(k, "identity", address(d.identity));
        vm.serializeAddress(k, "escrow", address(d.escrow));
        vm.serializeAddress(k, "receipt_registry", address(d.registry));
        vm.serializeAddress(k, "stake_vault", address(d.vault));
        vm.serializeAddress(k, "challenge_manager", address(d.challenges));
        vm.serializeAddress(k, "reputation_anchor", address(d.anchor));
        string memory json = vm.serializeString(k, "roles", rolesJson);
        string memory name = vm.envOr("DEPLOYMENT_NAME", string("base-sepolia"));
        vm.writeJson(json, string.concat("deployments/", name, ".json"));
    }
}
