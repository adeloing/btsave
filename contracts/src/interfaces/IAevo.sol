// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Aevo on-chain options router (Arbitrum L2)
interface IAevoRouter {
    /// @notice Open an options order
    /// @param underlying Token address (e.g. WBTC)
    /// @param isCall true=call, false=put
    /// @param strike Strike price (8 decimals, USD)
    /// @param amount Collateral amount in USDC (6 decimals)
    /// @param expiry Unix timestamp of option expiry
    /// @param premiumLimit Max premium willing to pay (6 decimals USDC). 0 = no limit.
    /// @return orderId Unique order identifier
    function openOrder(
        address underlying,
        bool isCall,
        uint256 strike,
        uint256 amount,
        uint256 expiry,
        uint256 premiumLimit
    ) external returns (bytes32 orderId);

    /// @notice Close an existing options position
    /// @return pnl Realized PnL in USDC (6 decimals), can be negative via int256
    function closeOrder(bytes32 orderId) external returns (int256 pnl);

    /// @notice Get current mark value of a position
    /// @return value Current position value in USDC (6 decimals)
    function getPositionValue(bytes32 orderId) external view returns (uint256 value);

    /// @notice Check if a position is still active
    function isPositionActive(bytes32 orderId) external view returns (bool);
}
