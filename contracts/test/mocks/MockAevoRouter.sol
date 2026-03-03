// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAevoRouter {
    uint256 private _counter;
    mapping(bytes32 => uint256) public positionValues;
    mapping(bytes32 => bool) public activePositions;
    mapping(bytes32 => int256) public closePnls;

    IERC20 public usdc;

    constructor(address _usdc) { usdc = IERC20(_usdc); }

    function setPositionValue(bytes32 id, uint256 val) external { positionValues[id] = val; }
    function setClosePnl(bytes32 id, int256 pnl) external { closePnls[id] = pnl; }

    function openOrder(
        address, bool, uint256, uint256 amount, uint256, uint256
    ) external returns (bytes32 orderId) {
        _counter++;
        orderId = bytes32(_counter);
        activePositions[orderId] = true;
        positionValues[orderId] = amount; // initial value = collateral
        // Pull USDC from caller
        usdc.transferFrom(msg.sender, address(this), amount);
    }

    function closeOrder(bytes32 orderId) external returns (int256 pnl) {
        activePositions[orderId] = false;
        pnl = closePnls[orderId];
    }

    function getPositionValue(bytes32 orderId) external view returns (uint256) {
        return positionValues[orderId];
    }

    function isPositionActive(bytes32 orderId) external view returns (bool) {
        return activePositions[orderId];
    }
}
