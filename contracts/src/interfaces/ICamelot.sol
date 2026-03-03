// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Camelot V2 Router on Arbitrum
interface ICamelotRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}
