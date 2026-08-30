// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice ABI-compatible mirror of this project's real
/// src/interfaces/IAggregatorV3.sol — duplicated here rather than
/// imported directly, since that file is pinned to Solidity ^0.8.26,
/// incompatible within one import graph with Reclaim's contracts
/// (hard-pinned to exactly 0.8.4). Matches the real Chainlink
/// AggregatorV3Interface signature exactly.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
