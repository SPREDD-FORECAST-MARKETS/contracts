// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import {BinaryAMMPredictionMarket} from "./SpreadMarket.sol";

/**
 * @title BinaryPredictionMarketFactory
 * @dev Factory contract to deploy and manage binary prediction markets using native tokens (ETH)
 */
contract BinaryPredictionMarketFactory is Ownable {
    // Market registry
    mapping(bytes32 => address) public markets;
    mapping(address => bytes32[]) public ownerMarkets;
    bytes32[] public allMarkets;
    
    // Market creation tracking
    uint256 public marketCount;
    
    /// @notice Events
    event MarketCreated(
        bytes32 indexed marketId,
        address indexed marketContract,
        address indexed owner,
        string question,
        string optionA,
        string optionB,
        uint256 endTime
    );

    constructor() {
        _setupOwner(msg.sender);
    }

    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @notice Create a new binary prediction market using native tokens
     * @param _question The market question
     * @param _optionA Option A description
     * @param _optionB Option B description
     * @param _duration Duration in seconds from now
     * @return marketId The unique market identifier
     * @return marketContract The deployed market contract address
     */
    function createMarket(
        string memory _question,
        string memory _optionA,
        string memory _optionB,
        uint256 _duration
    ) external returns (bytes32 marketId, address marketContract) {
        require(_duration > 0, "Duration must be positive");
        require(bytes(_optionA).length > 0 && bytes(_optionB).length > 0, "Options cannot be empty");
        require(bytes(_question).length > 0, "Question cannot be empty");

        // Generate unique market ID using hash of parameters and current state
        marketId = keccak256(abi.encodePacked(
            msg.sender,
            _question,
            _optionA,
            _optionB,
            block.timestamp,
            marketCount++
        ));

        // Ensure uniqueness (should be extremely rare to collide)
        require(markets[marketId] == address(0), "Market ID collision");

        uint256 endTime = block.timestamp + _duration;

        // Deploy new market contract (now uses native tokens)
        BinaryAMMPredictionMarket market = new BinaryAMMPredictionMarket(
            marketId,
            msg.sender, // market owner
            _question,
            _optionA,
            _optionB,
            endTime
        );

        marketContract = address(market);

        // Register market
        markets[marketId] = marketContract;
        ownerMarkets[msg.sender].push(marketId);
        allMarkets.push(marketId);

        emit MarketCreated(marketId, marketContract, msg.sender, _question, _optionA, _optionB, endTime);

        return (marketId, marketContract);
    }


    /**
     * @notice Get market count
     */
    function getMarketCount() external view returns (uint256) {
        return allMarkets.length;
    }

    /**
     * @notice Check if market exists
     */
    function marketExists(bytes32 _marketId) external view returns (bool) {
        return markets[_marketId] != address(0);
    }

    /**
     * @notice Get market prices by ID
     */
    function getMarketPrices(bytes32 _marketId) external view returns (uint256 priceA, uint256 priceB) {
        address marketAddr = markets[_marketId];
        require(marketAddr != address(0), "Market does not exist");
        
        BinaryAMMPredictionMarket market = BinaryAMMPredictionMarket(payable(marketAddr));
        return market.getCurrentPrices();
    }

    /**
     * @notice Get total value locked across all markets (in native tokens)
     */
    function getTotalValueLocked() external view returns (uint256 total) {
        for (uint256 i = 0; i < allMarkets.length; i++) {
            address marketAddr = markets[allMarkets[i]];
            if (marketAddr != address(0)) {
                total += marketAddr.balance;
            }
        }
    }

    // Allow factory to receive native tokens (in case needed for forwarding)
    receive() external payable {}
    fallback() external payable {}
}