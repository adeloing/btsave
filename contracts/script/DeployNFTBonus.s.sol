// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/NFTBonus.sol";

interface IMockSafe {
    function exec(address to, bytes calldata data) external returns (bool, bytes memory);
}

contract DeployNFTBonus is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address vaultAddr = 0x3Da4D2fb92D6cF7D3eF66C78eBf380DBBFb2df71;
        address safeAddr  = 0xC5D4397049AE8BfD7f59B37ee31169d4B8D18DfC;

        vm.startBroadcast(deployerKey);

        // 1. Deploy NFTBonus
        NFTBonus nft = new NFTBonus(
            vaultAddr,
            safeAddr,
            "https://ratpoison2.duckdns.org/nft/{id}.json"
        );

        console.log("NFTBonus:  ", address(nft));

        vm.stopBroadcast();
    }
}

contract SetNFTInVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address nftAddr = vm.envAddress("NFT_ADDRESS");
        address vaultAddr = 0x3Da4D2fb92D6cF7D3eF66C78eBf380DBBFb2df71;
        address safeAddr  = 0xC5D4397049AE8BfD7f59B37ee31169d4B8D18DfC;

        vm.startBroadcast(deployerKey);

        IMockSafe(safeAddr).exec(
            vaultAddr,
            abi.encodeWithSignature("setNFTContract(address)", nftAddr)
        );

        vm.stopBroadcast();
    }
}
