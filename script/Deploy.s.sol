// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ZeroXSixCIdentity} from "../src/ZeroXSixCIdentity.sol";

contract DeployScript is Script {
    uint256 internal constant ARBITRUM_ONE = 42161;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        uint256 chainId = block.chainid;
        require(chainId == ARBITRUM_ONE || chainId == ARBITRUM_SEPOLIA, "unsupported chain");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        ZeroXSixCIdentity implementation = new ZeroXSixCIdentity();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ZeroXSixCIdentity.initialize, (deployer)));

        vm.stopBroadcast();

        console.log("Chain id:", chainId);
        console.log("Deployer / owner:", deployer);
        console.log("Implementation:", address(implementation));
        console.log("Proxy:", address(proxy));
    }
}
