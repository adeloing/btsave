// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAevoRouter } from "../interfaces/IAevo.sol";

/// @notice Mock Aevo Router for fork testing
contract MockAevoRouter is IAevoRouter {
    uint256 private _nextId = 1;
    mapping(bytes32 => uint256) public positionValues;
    mapping(bytes32 => bool) public activePositions;

    function openOrder(
        address, bool, uint256, uint256 amount, uint256, uint256
    ) external override returns (bytes32 orderId) {
        orderId = bytes32(_nextId++);
        positionValues[orderId] = amount;
        activePositions[orderId] = true;
    }

    function closeOrder(bytes32 orderId) external override returns (int256) {
        activePositions[orderId] = false;
        uint256 val = positionValues[orderId];
        positionValues[orderId] = 0;
        return int256(val);
    }

    function getPositionValue(bytes32 orderId) external view override returns (uint256) {
        return positionValues[orderId];
    }

    function isPositionActive(bytes32 orderId) external view override returns (bool) {
        return activePositions[orderId];
    }
}
