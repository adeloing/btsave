// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MockERC20.sol";

contract MockAavePool {
    MockERC20 public aWbtc;
    MockERC20 public debtUsdc;
    IERC20 public wbtc;
    IERC20 public usdc;

    uint256 public healthFactor = 3e18; // default HF=3.0

    constructor(address _wbtc, address _usdc, address _aWbtc, address _debtUsdc) {
        wbtc = IERC20(_wbtc);
        usdc = IERC20(_usdc);
        aWbtc = MockERC20(_aWbtc);
        debtUsdc = MockERC20(_debtUsdc);
    }

    function setHealthFactor(uint256 hf) external { healthFactor = hf; }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (asset == address(wbtc)) {
            aWbtc.mint(onBehalfOf, amount);
        }
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        if (asset == address(wbtc)) {
            aWbtc.burn(msg.sender, amount);
            // Transfer the actual wbtc held by pool
            wbtc.transfer(to, amount);
        }
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        if (asset == address(usdc)) {
            debtUsdc.mint(onBehalfOf, amount);
            usdc.transfer(msg.sender, amount);
        }
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        if (asset == address(usdc)) {
            uint256 debt = debtUsdc.balanceOf(onBehalfOf);
            uint256 repayAmt = amount < debt ? amount : debt;
            IERC20(asset).transferFrom(msg.sender, address(this), repayAmt);
            debtUsdc.burn(onBehalfOf, repayAmt);
            return repayAmt;
        }
        return 0;
    }

    function getUserAccountData(address) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 hf
    ) {
        return (0, 0, 0, 0, 0, healthFactor);
    }
}
