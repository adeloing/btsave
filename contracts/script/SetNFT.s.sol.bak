// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

// Helper: calls MockSafe.execTransactionFromModule to forward call as the safe
// Since MockSafe.execTransactionFromModule just does to.call(data), 
// and the module address doesn't need to be registered for MockSafe,
// we can use this to make calls "from" the safe
interface IMockSafe {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 op) external returns (bool);
}

contract SetNFT is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address vaultAddr = 0x3Da4D2fb92D6cF7D3eF66C78eBf380DBBFb2df71;
        address safeAddr  = 0xC5D4397049AE8BfD7f59B37ee31169d4B8D18DfC;
        address nftAddr   = 0x2687Be75207868E92Aefe02a5d3a2D850ECB1F42;

        vm.startBroadcast(deployerKey);

        bool ok = IMockSafe(safeAddr).execTransactionFromModule(
            vaultAddr,
            0,
            abi.encodeWithSignature("setNFTContract(address)", nftAddr),
            0
        );
        require(ok, "execTransactionFromModule failed");

        vm.stopBroadcast();

        console.log("NFT set in vault OK");
    }
}
