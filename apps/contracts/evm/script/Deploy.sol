// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {addressDriverModuleData} from "script/modules/AddressDriver.sol";
import {callerModuleData} from "script/modules/Caller.sol";
import {dripsModuleData} from "script/modules/Drips.sol";
import {nftDriverModuleData} from "script/modules/NFTDriver.sol";
import {DeployCLI} from "script/utils/CLI.sol";
import {deployCreate3Factory, ICreate3Factory} from "script/utils/Create3Factory.sol";
import {writeDeploymentJson} from "script/utils/DeploymentJson.sol";
import {
    deployModulesDeployer, ModulesDeployer, ModuleData
} from "script/utils/ModulesDeployer.sol";

/// @notice Universal deployment script for all chains.
/// 
/// Usage: forge script script/Deploy.sol:Deploy --rpc-url <RPC_URL> --broadcast
/// The chain ID is automatically detected from the RPC.
///
/// Chain-specific notes:
/// - Filecoin (314): Foundry doesn't work well with Filecoin RPCs.
///   Pass `--gas-estimate-multiplier 80000 --slow` to `forge script`.
/// - ZkSync Sepolia (300): Different gas metering, always run with `--skip-simulation --slow`
/// - Local Anvil (31337): Use LocalTestnet.sol instead for test ERC-20 deployment
///
/// Supported chains:
/// - Filecoin (314)
/// - Metis (1088)
/// - Optimism (10)
/// - Optimism Sepolia (11155420)
/// - ZkSync Sepolia (300)
/// - Any other EVM chain
contract Deploy is Script {
    function run() public {
        uint256 chainId = block.chainid;
        bytes32 salt = DeployCLI.checkConfig(chainId);

        vm.startBroadcast();
        ICreate3Factory create3Factory = deployCreate3Factory();
        ModulesDeployer modulesDeployer = deployModulesDeployer(create3Factory, salt, msg.sender);

        address governor = msg.sender;

        // Deploy Caller and core Drips protocol
        ModuleData[] memory modules = new ModuleData[](2);
        modules[0] = callerModuleData(modulesDeployer);
        modules[1] = dripsModuleData(modulesDeployer, governor, 1 days);
        modulesDeployer.deployModules(modules);

        // Deploy drivers
        modules = new ModuleData[](2);
        modules[0] = addressDriverModuleData(modulesDeployer, governor);
        modules[1] = nftDriverModuleData(modulesDeployer, governor);
        modulesDeployer.deployModules(modules);

        vm.stopBroadcast();

        writeDeploymentJson(vm, modulesDeployer, salt);
    }
}
