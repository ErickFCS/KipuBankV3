// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockAggregatorV3
 * @notice Mocks a Chainlink Price Feed for testing.
 * @dev Allows setting the price and decimals.
 */
contract MockAggregatorV3 is AggregatorV3Interface {
    int256 private _price;
    uint8 private _decimals;

    constructor(int256 price, uint8 decimals_) {
        _price = price;
        _decimals = decimals_;
    }

    // --- Mutative Functions ---

    function setPrice(int256 price) public {
        _price = price;
    }

    // --- View Functions ---

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock ETH/USD";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData()
        public
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            1, // roundId
            _price, // answer
            block.timestamp, // startedAt
            block.timestamp, // updatedAt
            1 // answeredInRound
        );
    }

    function getRoundData(
        uint80
    )
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            1, // roundId
            _price, // answer
            block.timestamp, // startedAt
            block.timestamp, // updatedAt
            1 // answeredInRound
        );
    }
}
