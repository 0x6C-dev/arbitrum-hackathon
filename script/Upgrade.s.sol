// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ZeroXSixCIdentity} from "../src/ZeroXSixCIdentity.sol";

contract UpgradeScript is Script {
    uint256 internal constant ARBITRUM_ONE = 42161;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        uint256 chainId = block.chainid;
        require(chainId == ARBITRUM_ONE || chainId == ARBITRUM_SEPOLIA, "unsupported chain");

        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        ZeroXSixCIdentity proxy = ZeroXSixCIdentity(vm.envAddress("PROXY_ADDRESS"));
        require(proxy.owner() == vm.addr(ownerKey), "signer is not the proxy owner");

        vm.startBroadcast(ownerKey);

        ZeroXSixCIdentity implementation = new ZeroXSixCIdentity();
        proxy.upgradeToAndCall(address(implementation), "");

        vm.stopBroadcast();

        console.log("Chain id:", chainId);
        console.log("Proxy:", address(proxy));
        console.log("Implementation:", address(implementation));
        console.log("Version:", proxy.version());
    }
}
