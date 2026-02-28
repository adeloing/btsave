// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockSafe {
    mapping(address => bool) public owners;

    constructor() { owners[msg.sender] = true; }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8)
        external returns (bool) {
        (bool s,) = to.call{value: value}(data);
        return s;
    }

    // Allow anyone to call arbitrary function on a target (for setup)
    function exec(address to, bytes calldata data) external returns (bool, bytes memory) {
        return to.call(data);
    }

    function isOwner(address o) external view returns (bool) { return owners[o]; }
    function getOwners() external view returns (address[] memory) {
        address[] memory o = new address[](1); o[0] = msg.sender; return o;
    }
}

contract MockAavePool {
    uint256 public mockHF = 2e18;
    uint256 public mockCollateral = 500_000e8;

    function setHF(uint256 hf) external { mockHF = hf; }
    function setCollateral(uint256 c) external { mockCollateral = c; }

    function getUserAccountData(address) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256
    ) { return (mockCollateral, 0, 0, 0, 0, mockHF); }
}

contract MockOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 90000e8, 0, block.timestamp, 1);
    }
}

contract MockTarget {
    uint256 public value;
    function doSomething(uint256 v) external { value = v; }
}
