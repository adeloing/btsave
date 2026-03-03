// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice GMX V2 Exchange Router (Arbitrum) — order creation
interface IGMXExchangeRouter {
    struct CreateOrderParamsAddresses {
        address receiver;
        address callbackContract;
        address uiFeeReceiver;
        address market;
        address initialCollateralToken;
        address[] swapPath;
    }

    struct CreateOrderParamsNumbers {
        uint256 sizeDeltaUsd;                // 30 decimals
        uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice;
        uint256 acceptablePrice;             // 30 decimals
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 minOutputAmount;
    }

    struct CreateOrderParams {
        CreateOrderParamsAddresses addresses;
        CreateOrderParamsNumbers numbers;
        bytes32 orderType;          // 0x01=MarketIncrease, 0x04=MarketDecrease
        bytes32 decreasePositionSwapType;
        bool isLong;
        bool shouldUnwrapNativeToken;
        bytes32 referralCode;
    }

    function createOrder(CreateOrderParams calldata params) external payable returns (bytes32);
    function sendWnt(address receiver, uint256 amount) external payable;
    function sendTokens(address token, address receiver, uint256 amount) external;
}

/// @notice GMX V2 Reader — position queries
interface IGMXReader {
    struct PositionInfo {
        uint256 sizeInUsd;          // 30 decimals
        uint256 sizeInTokens;
        uint256 collateralAmount;
        int256 unrealizedPnl;       // 30 decimals
    }

    function getPosition(
        address dataStore,
        bytes32 positionKey
    ) external view returns (PositionInfo memory);
}

/// @notice GMX V2 callback — async order lifecycle
interface IOrderCallbackReceiver {
    function afterOrderExecution(bytes32 key, bytes calldata order, bytes calldata eventData) external;
    function afterOrderCancellation(bytes32 key, bytes calldata order, bytes calldata eventData) external;
    function afterOrderFrozen(bytes32 key, bytes calldata order, bytes calldata eventData) external;
}
