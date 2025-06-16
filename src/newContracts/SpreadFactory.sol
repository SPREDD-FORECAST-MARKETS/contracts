// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./SpreadMarketjp.sol";

/**
 * @title MarketFactory - FINAL STACK OPTIMIZED VERSION
 * @dev Factory contract for creating and managing SpreadMarket instances
 */
contract MarketFactory is Ownable {
    // USDT token interface
    IERC20 public usdtToken;
    
    // Platform fee recipient
    address public platformFeeRecipient;
    
    // SpreadMarket contract instance
    SpreadMarket public spreadMarketContract;
    
    // Market ID counter
    uint256 public marketIdCounter = 0;
    
    // Mapping of market ID to active status
    mapping(uint256 => bool) public isActiveMarket;
    
    // Mapping of creator addresses to their markets
    mapping(address => uint256[]) public creatorMarkets;
    
    // Mapping of factory market ID to SpreadMarket ID
    mapping(uint256 => uint256) public factoryToSpreadMarketId;
    
    // Events
    event MarketCreated(uint256 indexed marketId, address indexed creator, string question, uint256 expirationTime, string resolutionSource);
    event MarketDisabled(uint256 indexed marketId);
    event MarketEnabled(uint256 indexed marketId);
    
    /**
     * @dev Constructor
     */
    constructor(
        IERC20 _usdtToken,
        address _platformFeeRecipient,
        address _initialOwner
    ) 
        Ownable(_initialOwner)
    {
        require(address(_usdtToken) != address(0), "Invalid USDT address");
        require(_platformFeeRecipient != address(0), "Invalid platform fee recipient");
        require(_initialOwner != address(0), "Invalid initial owner");
        
        usdtToken = _usdtToken;
        platformFeeRecipient = _platformFeeRecipient;
        spreadMarketContract = new SpreadMarket(_usdtToken, _platformFeeRecipient, _initialOwner);
    }

    /**
     * @dev Creates a new prediction market
     */
    function createMarket(
        string memory _question,
        uint256 _expirationTime,
        string memory _resolutionSource
    ) external returns (uint256) {
        // Validate inputs
        require(bytes(_question).length > 0, "Question cannot be empty");
        require(_expirationTime > block.timestamp, "Expiration must be in future");
        require(bytes(_resolutionSource).length > 0, "Resolution source cannot be empty");
        
        // Check if user has sufficient balance and allowance
        uint256 requiredFee = spreadMarketContract.marketCreationFee();
        require(usdtToken.balanceOf(msg.sender) >= requiredFee, "Insufficient USDT balance");
        require(usdtToken.allowance(msg.sender, address(this)) >= requiredFee, "Insufficient USDT allowance to MarketFactory");
        
        // Transfer USDT from user to MarketFactory
        require(usdtToken.transferFrom(msg.sender, address(this), requiredFee), "USDT transfer to factory failed");
        
        // Approve SpreadMarket to spend the USDT
        require(usdtToken.approve(address(spreadMarketContract), requiredFee), "USDT approval to SpreadMarket failed");
        
        // Create market through the SpreadMarket contract
        uint256 spreadMarketId = spreadMarketContract.createMarket(_question, _expirationTime, _resolutionSource);
        
        // Increment our market ID counter
        marketIdCounter++;
        
        // Map factory market ID to SpreadMarket ID
        factoryToSpreadMarketId[marketIdCounter] = spreadMarketId;
        
        // Mark as active market
        isActiveMarket[marketIdCounter] = true;
        
        // Add to creator's markets
        creatorMarkets[msg.sender].push(marketIdCounter);
        
        emit MarketCreated(marketIdCounter, msg.sender, _question, _expirationTime, _resolutionSource);
        
        return marketIdCounter;
    }
    
    /**
     * @dev Get basic market info - Uses separate calls to avoid stack issues
     */
    function getMarketBasicInfo(uint256 factoryMarketId) external view returns (
        string memory question,
        uint256 expirationTime,
        address creator,
        uint256 yesLiquidity,
        uint256 noLiquidity,
        uint8 state
    ) {
        require(factoryMarketId > 0 && factoryMarketId <= marketIdCounter, "Invalid factory market ID");
        uint256 spreadMarketId = factoryToSpreadMarketId[factoryMarketId];
        
        // Get basic info through separate calls to avoid stack depth
        question = spreadMarketContract.getMarketQuestion(spreadMarketId);
        expirationTime = spreadMarketContract.getMarketExpirationTime(spreadMarketId);
        creator = spreadMarketContract.getMarketCreator(spreadMarketId);
        (yesLiquidity, noLiquidity) = spreadMarketContract.getMarketLiquidity(spreadMarketId);
        state = uint8(spreadMarketContract.getMarketState(spreadMarketId));
    }
    
    /**
     * @dev Get extended market info - Uses separate calls to avoid stack issues
     */
    function getMarketExtendedInfo(uint256 factoryMarketId) external view returns (
        uint8 resolvedSide,
        string memory resolutionSource,
        uint256 createdAt,
        uint256 resolvedAt,
        uint256 totalVolume,
        uint8 disputeState
    ) {
        require(factoryMarketId > 0 && factoryMarketId <= marketIdCounter, "Invalid factory market ID");
        uint256 spreadMarketId = factoryToSpreadMarketId[factoryMarketId];
        
        // Get extended info through separate calls
        resolvedSide = uint8(spreadMarketContract.getMarketResolvedSide(spreadMarketId));
        resolutionSource = spreadMarketContract.getMarketResolutionSource(spreadMarketId);
        createdAt = spreadMarketContract.getMarketCreatedAt(spreadMarketId);
        resolvedAt = spreadMarketContract.getMarketResolvedAt(spreadMarketId);
        totalVolume = spreadMarketContract.getMarketTotalVolume(spreadMarketId);
        disputeState = uint8(spreadMarketContract.getMarketDisputeState(spreadMarketId));
    }
    
    /**
     * @dev Get complete market info summary - Uses minimal destructuring
     */
    function getCompleteMarketInfo(uint256 factoryMarketId) external view returns (
        string memory question,
        address creator,
        uint256 expirationTime,
        uint8 state,
        uint256 totalVolume
    ) {
        require(factoryMarketId > 0 && factoryMarketId <= marketIdCounter, "Invalid factory market ID");
        uint256 spreadMarketId = factoryToSpreadMarketId[factoryMarketId];
        
        // Use individual getter functions to avoid stack issues
        question = spreadMarketContract.getMarketQuestion(spreadMarketId);
        creator = spreadMarketContract.getMarketCreator(spreadMarketId);
        expirationTime = spreadMarketContract.getMarketExpirationTime(spreadMarketId);
        state = uint8(spreadMarketContract.getMarketState(spreadMarketId));
        totalVolume = spreadMarketContract.getMarketTotalVolume(spreadMarketId);
    }
    
    /**
     * @dev Check if user can create a market
     */
    function canUserCreateMarket(address user) external view returns (bool canCreate, string memory reason) {
        uint256 requiredFee = spreadMarketContract.marketCreationFee();
        uint256 userBalance = usdtToken.balanceOf(user);
        
        if (userBalance < requiredFee) {
            return (false, "Insufficient USDT balance");
        }
        
        if (usdtToken.allowance(user, address(this)) < requiredFee) {
            return (false, "Insufficient USDT allowance to MarketFactory");
        }
        
        return (true, "Ready to create market");
    }
    
    /**
     * @dev Get market creation requirements
     */
    function getMarketCreationInfo(address user) external view returns (
        uint256 requiredFee,
        uint256 userBalance,
        uint256 userAllowance,
        address spreadMarketAddress
    ) {
        requiredFee = spreadMarketContract.marketCreationFee();
        userBalance = usdtToken.balanceOf(user);
        userAllowance = usdtToken.allowance(user, address(this));
        spreadMarketAddress = address(spreadMarketContract);
    }
    
    /**
     * @dev Get SpreadMarket ID from Factory ID
     */
    function getSpreadMarketId(uint256 factoryMarketId) external view returns (uint256) {
        require(factoryMarketId > 0 && factoryMarketId <= marketIdCounter, "Invalid factory market ID");
        return factoryToSpreadMarketId[factoryMarketId];
    }
    
    /**
     * @dev Get active markets
     */
    function getActiveMarkets() external view returns (uint256[] memory) {
        // Count active markets first
        uint256 count = 0;
        for (uint256 i = 1; i <= marketIdCounter; i++) {
            if (isActiveMarket[i]) {
                count++;
            }
        }
        
        // Create array and populate
        uint256[] memory activeMarkets = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i <= marketIdCounter; i++) {
            if (isActiveMarket[i]) {
                activeMarkets[index] = i;
                index++;
            }
        }
        
        return activeMarkets;
    }
    
    /**
     * @dev Disable a market
     */
    function disableMarket(uint256 _marketId) external onlyOwner {
        require(_marketId > 0 && _marketId <= marketIdCounter, "Invalid market ID");
        require(isActiveMarket[_marketId], "Market not active");
        
        isActiveMarket[_marketId] = false;
        emit MarketDisabled(_marketId);
    }
    
    /**
     * @dev Enable a previously disabled market
     */
    function enableMarket(uint256 _marketId) external onlyOwner {
        require(_marketId > 0 && _marketId <= marketIdCounter, "Invalid market ID");
        require(!isActiveMarket[_marketId], "Market already active");
        
        isActiveMarket[_marketId] = true;
        emit MarketEnabled(_marketId);
    }
    
    /**
     * @dev Get all markets
     */
    function getAllMarkets() external view returns (uint256[] memory) {
        uint256[] memory markets = new uint256[](marketIdCounter);
        for (uint256 i = 0; i < marketIdCounter; i++) {
            markets[i] = i + 1;
        }
        return markets;
    }
    
    /**
     * @dev Get markets created by a specific creator
     */
    function getCreatorMarkets(address _creator) external view returns (uint256[] memory) {
        return creatorMarkets[_creator];
    }

    /**
     * @dev Update platform fee recipient
     */
    function updatePlatformFeeRecipient(address _platformFeeRecipient) external onlyOwner {
        require(_platformFeeRecipient != address(0), "Invalid recipient address");
        platformFeeRecipient = _platformFeeRecipient;
        spreadMarketContract.updatePlatformFeeRecipient(_platformFeeRecipient);
    }
    
    /**
     * @dev Get SpreadMarket contract address
     */
    function getSpreadMarketAddress() external view returns (address) {
        return address(spreadMarketContract);
    }
    
    /**
     * @dev Emergency function to recover USDT
     */
    function recoverUSDT(uint256 amount) external onlyOwner {
        require(usdtToken.transfer(owner(), amount), "USDT recovery failed");
    }
}