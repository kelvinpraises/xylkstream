// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {VmSafe} from "forge-std/Script.sol";
import {
    addressDriverModule, isAddressDriverModuleDeployed
} from "script/modules/AddressDriver.sol";
import {Drips, dripsModule, isDripsModuleDeployed} from "script/modules/Drips.sol";
import {isNFTDriverModuleDeployed, nftDriverModule} from "script/modules/NFTDriver.sol";
import {isModuleDeployed, ModulesDeployer} from "script/utils/ModulesDeployer.sol";

function writeDeploymentJson(VmSafe vm, ModulesDeployer modulesDeployer, bytes32 salt) {
    string memory objectKey = "deployment JSON";

    if (isDripsModuleDeployed(modulesDeployer)) {
        Drips drips = dripsModule(modulesDeployer).drips();
        vm.serializeAddress(objectKey, "Drips", address(drips));
        vm.serializeUint(objectKey, "Drips cycle seconds", drips.cycleSecs());
    }

    if (isAddressDriverModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey,
            "AddressDriver",
            address(addressDriverModule(modulesDeployer).addressDriver())
        );
    }

    if (isNFTDriverModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey, "NFTDriver", address(nftDriverModule(modulesDeployer).nftDriver())
        );
    }

    vm.serializeAddress(objectKey, "ModulesDeployer", address(modulesDeployer));
    vm.serializeString(objectKey, "Salt", vm.split(string(bytes.concat(salt)), "\x00")[0]);
    vm.serializeAddress(objectKey, "Deployer", msg.sender);
    string memory json = vm.serializeUint(objectKey, "Chain ID", block.chainid);

    vm.writeJson(json, "deployment.json");
}
