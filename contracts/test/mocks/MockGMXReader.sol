// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/interfaces/IGMXV2.sol";

contract MockGMXReader {
    mapping(bytes32 => IGMXReader.PositionInfo) public positions;

    function setPosition(bytes32 key, uint256 sizeInUsd, uint256 collateralAmount, int256 pnl) external {
        positions[key] = IGMXReader.PositionInfo(sizeInUsd, 0, collateralAmount, pnl);
    }

    function getPosition(address, bytes32 positionKey) external view returns (IGMXReader.PositionInfo memory) {
        return positions[positionKey];
    }
}
