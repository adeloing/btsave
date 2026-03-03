// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/interfaces/IStrategyOnChain.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal mock strategy for vault tests (doesn't need full AAVE/GMX infra)
contract MockStrategy is IStrategyOnChain {
    IERC20 public wbtc;
    uint256 public totalDeposited;
    uint256 public ath;
    uint256 public price;

    constructor(address _wbtc) { wbtc = IERC20(_wbtc); }

    function setATH(uint256 _ath) external { ath = _ath; }
    function setPrice(uint256 _price) external { price = _price; }

    function currentATH() external view override returns (uint256) { return ath; }
    function currentPrice() external view override returns (uint256) { return price; }

    function totalAssets() external view override returns (uint256) { return totalDeposited; }

    function setTotalDeposited(uint256 val) external { totalDeposited = val; }

    function deposit(uint256 amount) external override {
        wbtc.transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
    }

    function withdraw(uint256 amount, address to) external override returns (uint256) {
        if (amount > totalDeposited) amount = totalDeposited;
        totalDeposited -= amount;
        wbtc.transfer(to, amount);
        return amount;
    }
}
