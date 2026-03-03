// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategyOnChain {
    function totalAssets() external view returns (uint256);
    function currentATH() external view returns (uint256);
    function currentPrice() external view returns (uint256);
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount, address to) external returns (uint256);
}
