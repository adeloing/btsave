// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/interfaces/IGMXV2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockGMXExchangeRouter {
    uint256 private _orderCounter;

    function createOrder(IGMXExchangeRouter.CreateOrderParams calldata) external payable returns (bytes32) {
        _orderCounter++;
        return bytes32(_orderCounter);
    }

    function sendWnt(address, uint256) external payable {}
    function sendTokens(address token, address receiver, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, receiver, amount);
    }
}
