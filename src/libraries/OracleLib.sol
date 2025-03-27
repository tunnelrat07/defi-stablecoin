// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Tunnel Rat
 * @notice This library is written to  check the Chainlink oracle for stale data
 * If the price is stale the function will revert and render the DSC engine unusable - this is by design
 * We want the DSC Engine to freeze if the prices become stale
 */
library OracleLib {
    error OracleLib__StalePrice();
    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 seconds

    function stalePriceCheck(
        AggregatorV3Interface priceFeed
    ) public view returns (uint80, int256, uint256, uint256, uint80) {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
