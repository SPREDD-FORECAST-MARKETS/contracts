// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BinaryAMMPredictionMarket} from "./SpreddMarket.sol";
import {WeeklyForecastPointManager} from "../FPManager.sol";

/**
 * @title BinaryPredictionMarketFactory
 * @dev Factory contract to deploy and manage binary prediction markets using ERC-20 tokens
 */
contract BinaryPredictionMarketFactory is Ownable {

    using SafeERC20 for IERC20;

    // Market registry
    mapping(bytes32 => address) public markets;
    mapping(address => bytes32[]) public ownerMarkets;
    mapping(address => bytes32[]) public tokenMarkets; // Markets by token address
    bytes32[] public allMarkets;

    WeeklyForecastPointManager public fpManager;

    // Trading Token
    address public tradingToken;
    
    // Market creation tracking
    uint256 public marketCount;
    
    // Supported tokens for creating markets
    mapping(address => bool) public supportedTokens;
    address[] public supportedTokensList;

    /// @notice Events
    event MarketCreated(
        bytes32 indexed marketId,
        address indexed marketContract,
        address indexed owner,
        address token,
        string question,
        string optionA,
        string optionB,
        uint256 endTime
    );

    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    constructor(address _token) {
        _setupOwner(msg.sender);
        tradingToken = _token;
    }

    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @notice Add a supported ERC-20 token for market creation
     * @param _token The ERC-20 token address to add
     */
    function addSupportedToken(address _token) external {
        require(msg.sender == owner(), "Only owner can add tokens");
        require(_token != address(0), "Invalid token address");
        require(!supportedTokens[_token], "Token already supported");

        supportedTokens[_token] = true;
        supportedTokensList.push(_token);

        emit TokenAdded(_token);
    }

    /**
     * @notice Remove a supported ERC-20 token
     * @param _token The ERC-20 token address to remove
     */
    function removeSupportedToken(address _token) external {
        require(msg.sender == owner(), "Only owner can remove tokens");
        require(supportedTokens[_token], "Token not supported");

        supportedTokens[_token] = false;
        
        // Remove from supportedTokensList array
        for (uint256 i = 0; i < supportedTokensList.length; i++) {
            if (supportedTokensList[i] == _token) {
                supportedTokensList[i] = supportedTokensList[supportedTokensList.length - 1];
                supportedTokensList.pop();
                break;
            }
        }

        emit TokenRemoved(_token);
    }

    /**
     * @notice Create a new binary prediction market using ERC-20 tokens
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
            this.tradingToken,
            _question,
            _optionA,
            _optionB,
            block.timestamp,
            marketCount++
        ));

        // Ensure uniqueness (should be extremely rare to collide)
        require(markets[marketId] == address(0), "Market ID collision");

        uint256 endTime = block.timestamp + _duration;

        // Deploy new market contract (now uses ERC-20 tokens)
        BinaryAMMPredictionMarket market = new BinaryAMMPredictionMarket(
            marketId,
            msg.sender, // market owner
            this.tradingToken(),     // ERC-20 token address
            _question,
            _optionA,
            _optionB,
            endTime,
            address(fpManager)
        );

        marketContract = address(market);

        // Register market
        markets[marketId] = marketContract;
        ownerMarkets[msg.sender].push(marketId);
        tokenMarkets[this.tradingToken()].push(marketId);
        allMarkets.push(marketId);

        fpManager.setAuthorizedContract(address(marketContract), true);

        fpManager.awardCreatorFP(
            msg.sender,      // creator
            marketId,        // market ID
            0,              // initial volume = 0
            0               // initial trade count = 0
        );


        emit MarketCreated(marketId, marketContract, msg.sender, this.tradingToken(), _question, _optionA, _optionB, endTime);

        return (marketId, marketContract);
    }

    /**
     * @notice Set FP Manager
     * @param _fpManager The FP Manager contract address
     */
    function setFPManager(address _fpManager) external {
        require(msg.sender == owner(), "only owner can call this method");
        fpManager = WeeklyForecastPointManager(_fpManager);
    }

    /**
     * @notice Get markets by owner
     * @param _owner The owner address
     * @return Array of market IDs owned by the address
     */
    function getMarketsByOwner(address _owner) external view returns (bytes32[] memory) {
        return ownerMarkets[_owner];
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
     * @notice Get market contract address by ID
     */
    function getMarketAddress(bytes32 _marketId) external view returns (address) {
        return markets[_marketId];
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
     * @notice Get market token address by ID
     */
    function getMarketToken(bytes32 _marketId) external view returns (address) {
        address marketAddr = markets[_marketId];
        require(marketAddr != address(0), "Market does not exist");
        
        BinaryAMMPredictionMarket market = BinaryAMMPredictionMarket(marketAddr);
        return market.getTokenAddress();
    }

    /**
     * @notice Get total value locked across all markets (returns array for each supported token)
     * @return tokens Array of token addresses
     * @return values Array of total values locked for each token
     */
    function getTotalValueLocked() external view returns (address[] memory tokens, uint256[] memory values) {
        tokens = supportedTokensList;
        values = new uint256[](supportedTokensList.length);
        
        for (uint256 i = 0; i < supportedTokensList.length; i++) {
            address token = supportedTokensList[i];
            bytes32[] memory tokenMarketIds = tokenMarkets[token];
            
            for (uint256 j = 0; j < tokenMarketIds.length; j++) {
                address marketAddr = markets[tokenMarketIds[j]];
                if (marketAddr != address(0)) {
                    BinaryAMMPredictionMarket market = BinaryAMMPredictionMarket(marketAddr);
                    values[i] += market.getTotalValue();
                }
            }
        }
    }

}