// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockCamelotRouter {
    // Fixed rate: 1 WBTC (1e8) = 60000 USDC (60000e6)
    uint256 public wbtcPriceUsdc = 60000e6;
    address public wbtcAddr;
    address public usdcAddr;

    function setTokens(address _wbtc, address _usdc) external {
        wbtcAddr = _wbtc;
        usdcAddr = _usdc;
    }

    function setWbtcPrice(uint256 price) external { wbtcPriceUsdc = price; }

    function _calcOutput(uint256 amountIn, address tokenIn) internal view returns (uint256) {
        if (tokenIn == usdcAddr) {
            // USDC → WBTC: amountIn(6dec) * 1e8 / price(6dec)
            return (amountIn * 1e8) / wbtcPriceUsdc;
        } else {
            // WBTC → USDC: amountIn(8dec) * price(6dec) / 1e8
            return (amountIn * wbtcPriceUsdc) / 1e8;
        }
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        if (path.length >= 2) {
            amounts[1] = amountIn;
        }
        if (path.length >= 3) {
            amounts[2] = _calcOutput(amountIn, path[0]);
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256
    ) external returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);

        uint256 outAmount = _calcOutput(amountIn, path[0]);
        if (path.length >= 2) amounts[1] = amountIn;
        if (path.length >= 3) amounts[2] = outAmount;

        require(outAmount >= amountOutMin, "MockCamelot: slippage");
        IERC20(path[path.length - 1]).transfer(to, outAmount);
    }
}
