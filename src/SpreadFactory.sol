// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import {IERC20} from "@thirdweb-dev/contracts/eip/interface/IERC20.sol";
import {BinaryAMMPredictionMarket} from "./SpreadMarket.sol";


/**
 * @title BinaryPredictionMarketFactory
 * @dev Factory contract to deploy and manage binary prediction markets
 */
contract BinaryPredictionMarketFactory is Ownable {
    IERC20 public bettingToken;
    
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

    constructor(address _bettingToken) {
        bettingToken = IERC20(_bettingToken);
        _setupOwner(msg.sender);
    }

    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @notice Create a new binary prediction market
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

        // Deploy new market contract
        BinaryAMMPredictionMarket market = new BinaryAMMPredictionMarket(
            marketId,
            address(bettingToken),
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
     * @notice Get market contract address by ID
     */
    function getMarket(bytes32 _marketId) external view returns (address) {
        return markets[_marketId];
    }

    /**
     * @notice Get all markets created by an owner
     */
    function getOwnerMarkets(address _owner) external view returns (bytes32[] memory) {
        return ownerMarkets[_owner];
    }

    /**
     * @notice Get all market IDs
     */
    function getAllMarkets() external view returns (bytes32[] memory) {
        return allMarkets;
    }

    /**
     * @notice Get market count
     */
    function getMarketCount() external view returns (uint256) {
        return allMarkets.length;
    }

    /**
     * @notice Get market info by ID
     */
    function getMarketInfo(bytes32 _marketId) external view returns (
        address marketContract,
        address marketOwner,
        string memory question,
        string memory optionA,
        string memory optionB,
        uint256 endTime,
        bool initialized,
        bool resolved
    ) {
        address marketAddr = markets[_marketId];
        require(marketAddr != address(0), "Market does not exist");
        
        BinaryAMMPredictionMarket market = BinaryAMMPredictionMarket(marketAddr);
        
        marketContract = marketAddr;
        marketOwner = market.owner();
        
        (
            question,
            endTime,
            ,  // outcome - not needed here
            optionA,
            optionB,
            ,  // sharesA - not needed here
            ,  // sharesB - not needed here
            ,  // k - not needed here
            resolved,
            initialized,
            // totalLpTokens - not needed here
        ) = market.marketInfo();
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
        
        BinaryAMMPredictionMarket market = BinaryAMMPredictionMarket(marketAddr);
        return market.getCurrentPrices();
    }

    /**
     * @notice Batch get market info for multiple markets
     */
    function batchGetMarketInfo(bytes32[] calldata _marketIds) external view returns (
        address[] memory marketContracts,
        uint256[] memory pricesA,
        uint256[] memory pricesB,
        bool[] memory initialized,
        bool[] memory resolved
    ) {
        uint256 length = _marketIds.length;
        marketContracts = new address[](length);
        pricesA = new uint256[](length);
        pricesB = new uint256[](length);
        initialized = new bool[](length);
        resolved = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            address marketAddr = markets[_marketIds[i]];
            if (marketAddr != address(0)) {
                BinaryAMMPredictionMarket market = BinaryAMMPredictionMarket(marketAddr);
                marketContracts[i] = marketAddr;
                (pricesA[i], pricesB[i]) = market.getCurrentPrices();
                
                (
                    ,  // question
                    ,  // endTime
                    ,  // outcome
                    ,  // optionA
                    ,  // optionB
                    ,  // sharesA
                    ,  // sharesB
                    ,  // k
                    resolved[i],
                    initialized[i],
                    // totalLpTokens
                ) = market.marketInfo();
            }
        }
    }
}