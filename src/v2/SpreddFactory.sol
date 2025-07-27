// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SpreddMarket} from "./SpreddMarket.sol";
import {WeeklyForecastPointManager} from "./FPManager.sol";

/**
* @title SpreddMarketFactory
* @dev Factory contract to deploy and manage binary bet prediction markets
* Similar structure to BinaryAMMPredictionMarketFactory but for bet-based markets
*/
contract SpreddMarketFactory is Ownable {
    using SafeERC20 for IERC20;

    // Market registry
    mapping(bytes32 => address) public markets;
    mapping(address => bytes32[]) public ownerMarkets;
    mapping(address => bytes32[]) public tokenMarkets; // Markets by token address
    bytes32[] public allMarkets;

    // Trading Token
    address public tradingToken;
    
    // Market creation tracking
    uint256 public marketCount;
    
    // Supported tokens for creating markets
    mapping(address => bool) public supportedTokens;
    address[] public supportedTokensList;

    // Market creation fee
    uint256 public marketCreationFee = 0.001 ether; // ETH fee for creating markets
    
    // Factory fee collection
    uint256 public collectedFees; // Total factory fees collected

    WeeklyForecastPointManager public fpManager;

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
    event MarketCreationFeeUpdated(uint256 newFee);
    event FactoryFeesWithdrawn(address indexed to, uint256 amount);

    constructor(address _token) {
        _setupOwner(msg.sender);
        tradingToken = _token;
        
        // Add the trading token as supported by default
        supportedTokens[_token] = true;
        supportedTokensList.push(_token);
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
    * @notice Set market creation fee
    * @param _newFee New fee amount in ETH
    */
    function setMarketCreationFee(uint256 _newFee) external {
        require(msg.sender == owner(), "Only owner can set fee");
        marketCreationFee = _newFee;
        emit MarketCreationFeeUpdated(_newFee);
    }

    function createMarket(
        string memory _question,
        string memory _optionA,
        string memory _optionB,
        uint256 _endTime
    ) external payable returns (bytes32 marketId, address marketContract) {
        require(_endTime > block.timestamp, "End time must be in the future"); // FIXED: Changed < to >
        require(bytes(_optionA).length > 0 && bytes(_optionB).length > 0, "Options cannot be empty");
        require(bytes(_question).length > 0, "Question cannot be empty");
        require(
            IERC20(tradingToken).transferFrom(msg.sender, address(this), marketCreationFee),
            "ERC20: Fee transfer failed"
        );

        // Generate unique market ID using hash of parameters and current state
        marketId = keccak256(abi.encodePacked(
            msg.sender,
            tradingToken,
            _question,
            _optionA,
            _optionB,
            block.timestamp,
            marketCount++
        ));

        // Ensure uniqueness (should be extremely rare to collide)
        require(markets[marketId] == address(0), "Market ID collision");

        // FIXED: Use the provided _endTime parameter, not block.timestamp
        uint256 endTime = _endTime;

        // Deploy new bet-based market contract
        SpreddMarket market = new SpreddMarket(
            marketId,
            msg.sender, // market owner
            tradingToken, // ERC-20 token address
            _question,
            _optionA,
            _optionB,
            _endTime, // FIXED: Use _endTime consistently
            address(fpManager)
        );

        marketContract = address(market);

        // Register market
        markets[marketId] = marketContract;
        ownerMarkets[msg.sender].push(marketId);
        tokenMarkets[tradingToken].push(marketId);
        allMarkets.push(marketId);

        // Forward creation fee to owner
        if (msg.value > 0) {
            payable(owner()).transfer(msg.value);
        }

        fpManager.setAuthorizedContract(address(marketContract), true);

        fpManager.awardCreatorFP(
            msg.sender,      // creator
            marketId,        // market ID
            0,              // initial volume = 0
            0               // initial trade count = 0
        );

        emit MarketCreated(marketId, marketContract, msg.sender, tradingToken, _question, _optionA, _optionB, endTime);

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
    * @notice Receive factory fees from markets (called by market contracts)
    */
    function receiveFactoryFees(uint256 _amount) external {
        // Verify caller is a valid market
        bool isValidMarket = false;
        for (uint256 i = 0; i < allMarkets.length; i++) {
            if (markets[allMarkets[i]] == msg.sender) {
                isValidMarket = true;
                break;
            }
        }
        require(isValidMarket, "Only markets can send fees");

        IERC20(tradingToken).safeTransferFrom(msg.sender, address(this), _amount);
        collectedFees += _amount;
    }

    /**
    * @notice Withdraw collected factory fees
    */
    function withdrawFactoryFees(address _to) external {
        require(msg.sender == owner(), "Only owner can withdraw fees");
        require(_to != address(0), "Invalid recipient");

        uint256 balance = IERC20(tradingToken).balanceOf(address(this));

        IERC20(tradingToken).safeTransfer(_to, balance);
        emit FactoryFeesWithdrawn(_to, balance);
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
    * @notice Get all markets
    * @return Array of all market IDs
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
    * @notice Get market odds by ID
    */
    function getMarketOdds(bytes32 _marketId) external view returns (uint256 oddsA, uint256 oddsB, uint256 totalVolume) {
        address marketAddr = markets[_marketId];
        require(marketAddr != address(0), "Market does not exist");
        
        SpreddMarket market = SpreddMarket(marketAddr);
        return market.getMarketOdds();
    }

    /**
    * @notice Get market token address by ID
    */
    function getMarketToken(bytes32 _marketId) external view returns (address) {
        address marketAddr = markets[_marketId];
        require(marketAddr != address(0), "Market does not exist");
        
        SpreddMarket market = SpreddMarket(marketAddr);
        return market.getTokenAddress();
    }

    /**
    * @notice Get supported tokens list
    */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokensList;
    }

    /**
    * @notice Get total value locked across all markets
    * @return totalTVL Total value locked across all markets
    */
    function getTotalValueLocked() external view returns (uint256 totalTVL) {
        for (uint256 i = 0; i < allMarkets.length; i++) {
            address marketAddr = markets[allMarkets[i]];
            if (marketAddr != address(0)) {
                SpreddMarket market = SpreddMarket(marketAddr);
                totalTVL += market.getTotalValue();
            }
        }
    }

    /**
    * @notice Get markets by token
    * @param _token Token address
    * @return Array of market IDs using the specified token
    */
    function getMarketsByToken(address _token) external view returns (bytes32[] memory) {
        return tokenMarkets[_token];
    }

    /**
    * @notice Get comprehensive market stats
    * @return totalMarkets Total number of markets
    * @return totalTVL Total value locked
    * @return activeMarkets Number of active (unresolved) markets
    * @return totalBets Total number of bets across all markets
    * @return totalBettors Total unique bettors across all markets
    */
    function getMarketStats() external view returns (
        uint256 totalMarkets,
        uint256 totalTVL,
        uint256 activeMarkets,
        uint256 totalBets,
        uint256 totalBettors
    ) {
        totalMarkets = allMarkets.length;
        
        for (uint256 i = 0; i < allMarkets.length; i++) {
            address marketAddr = markets[allMarkets[i]];
            if (marketAddr != address(0)) {
                SpreddMarket market = SpreddMarket(marketAddr);
                
                // Get market value
                totalTVL += market.getTotalValue();
                
                // Check if market is still active
                (, , , , , bool resolved, ) = market.getMarketInfo();
                if (!resolved) {
                    activeMarkets++;
                }
                
                // Get bet statistics
                (, , , , , uint256 marketBets,) = market.getMarketVolumes();
                totalBets += marketBets;
                
                // Get unique bettors for this market
                totalBettors += market.getBettorCount();
            }
        }
    }

    /**
    * @notice Get detailed market information
    */
    function getMarketDetails(bytes32 _marketId) external view returns (
        string memory question,
        string memory optionA,
        string memory optionB,
        uint256 endTime,
        bool resolved,
        uint256 volumeA,
        uint256 volumeB,
        uint256 totalVolume,
        uint256 oddsA,
        uint256 oddsB,
        uint256 bettorCount
    ) {
        address marketAddr = markets[_marketId];
        require(marketAddr != address(0), "Market does not exist");
        
        SpreddMarket market = SpreddMarket(marketAddr);
        
        // Get basic info
        (question, optionA, optionB, endTime, , resolved, ) = market.getMarketInfo();
        
        // Get volume info
        (volumeA, volumeB, totalVolume, , , ,) = market.getMarketVolumes();
        
        // Get odds
        (oddsA, oddsB, ) = market.getMarketOdds();
        
        // Get bettor count
        bettorCount = market.getBettorCount();
    }

    /**
    * @notice Get current market creation fee
    */
    function getMarketCreationFee() external view returns (uint256) {
        return marketCreationFee;
    }

    /**
    * @notice Check if token is supported
    */
    function isTokenSupported(address _token) external view returns (bool) {
        return supportedTokens[_token];
    }

    /**
    * @notice Get collected factory fees
    */
    function getCollectedFees() external view returns (uint256) {
        return collectedFees;
    }

    /**
    * @notice Emergency function to withdraw ETH (only owner)
    */
    function withdrawETH() external {
        require(msg.sender == owner(), "Only owner can withdraw");
        payable(owner()).transfer(address(this).balance);
    }

    /**
    * @notice Receive function - only accept ETH for market creation
    */
    receive() external payable {
        revert("Use createMarket to send ETH");
    }

    /**
    * @notice Fallback function - revert
    */
    fallback() external payable {
        revert("Function not found");
    }
}