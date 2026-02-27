// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleManager {
    function isRedemptionWindowOpen() external view returns (bool);
    function getSpotPrice() external view returns (uint256);
}

interface IStrategyHybridAccumulator {
    function reportDeribitBalance(uint256 usdcBalance) external;
    function resetCycle() external;
}

interface ITurboPaperBoatVault {
    function harvest() external;
    function updateDeribitBalance(uint256 usdcBalance) external;
}

interface INFTCycleRewards {
    function requestMint(address user, uint256 avgBalanceUSDC) external returns (uint256 requestId);
    function testMint(address user, uint256 avgBalanceUSDC) external;
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}