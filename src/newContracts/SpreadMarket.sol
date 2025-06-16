// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./ForecastPointsjp.sol";

/**
 * @title SpreadMarket - CORRECTED VERSION
 * @dev Main contract for prediction markets with leaderboard points
 */
contract SpreadMarket is Ownable, ReentrancyGuard {
    // Market states
    enum MarketState { Active, Expired, Resolved, Disputed }
    
    // Market sides
    enum Side { Yes, No }
    
    // Dispute states
    enum DisputeState { None, Pending, Resolved }
    
    // Market structure
    struct Market {
        string question;
        uint256 expirationTime;
        address creator;
        uint256 yesLiquidity;
        uint256 noLiquidity;
        MarketState state;
        Side resolvedSide;
        string resolutionSource;
        uint256 createdAt;
        uint256 resolvedAt;
        uint256 totalVolume;
        DisputeState disputeState;
    }
    
    // Forecast structure
    struct Forecast {
        address user;
        uint256 marketId;
        Side side;
        uint256 amount;
        uint256 timestamp;
        bool claimed;
    }
    
    // USDT token interface
    IERC20 public usdtToken;
    
    // ForecastPoints contract
    ForecastPoints public forecastPoints;
    
    // Platform fee recipient
    address public platformFeeRecipient;
    
    // Market creation fee (in USDT)
    uint256 public marketCreationFee = 10 * 10**6; // 10 USDT (with 6 decimals)
    
    // Platform fee percentage
    uint256 public platformFeePercentage = 2500; // 25% in basis points
    
    // Reward pool percentage
    uint256 public rewardPoolPercentage = 5000; // 50% in basis points
    
    // Creator reward pool percentage
    uint256 public creatorRewardPoolPercentage = 2500; // 25% in basis points
    
    // Total markets created
    uint256 public totalMarkets;
    
    // Mapping of market ID to market data
    mapping(uint256 => Market) public markets;
    
    // Mapping of market ID to forecasts
    mapping(uint256 => Forecast[]) public forecasts;
    
    // Mapping of user address to array of market IDs they've participated in
    mapping(address => uint256[]) public userMarkets;
    
    // Mapping of user address to array of market IDs they've created
    mapping(address => uint256[]) public creatorMarkets;
    
    // Weekly reward pool
    mapping(uint256 => uint256) public weeklyRewardPool;
    
    // Weekly creator reward pool
    mapping(uint256 => uint256) public weeklyCreatorRewardPool;
    
    // Events
    event MarketCreated(uint256 indexed marketId, address indexed creator, string question, uint256 expirationTime, string resolutionSource);
    event ForecastMade(uint256 indexed marketId, address indexed forecaster, Side side, uint256 amount);
    event MarketResolved(uint256 indexed marketId, Side resolvedSide, address resolver);
    event MarketDisputed(uint256 indexed marketId, address disputer, string reason);
    event DisputeResolved(uint256 indexed marketId, bool upheld, address resolver);
    event PointsClaimed(uint256 indexed marketId, address indexed user, uint256 points);
    event WeeklyRewardPoolUpdated(uint256 indexed weekNumber, uint256 amount);
    event WeeklyCreatorRewardPoolUpdated(uint256 indexed weekNumber, uint256 amount);
    
    /**
     * @dev Constructor
     * @param _usdtToken USDT token contract address
     * @param _platformFeeRecipient Address to receive platform fees
     * @param _initialOwner Initial owner of the contract
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
        
        // Create ForecastPoints contract
        forecastPoints = new ForecastPoints(_initialOwner);
    }
        
    /**
     * @dev Create a new prediction market - CORRECTED VERSION
     * @param _question Question to be answered
     * @param _expirationTime Time when the market expires
     * @param _resolutionSource Source for resolution information
     */
    function createMarket(
        string memory _question,
        uint256 _expirationTime,
        string memory _resolutionSource
    ) external nonReentrant returns (uint256) {
        // Input validation
        require(bytes(_question).length > 0, "Question cannot be empty");
        require(bytes(_question).length <= 500, "Question too long");
        require(_expirationTime > block.timestamp, "Expiration must be in future");
        require(_expirationTime <= block.timestamp + 365 days, "Expiration too far in future");
        require(bytes(_resolutionSource).length > 0, "Resolution source cannot be empty");
        require(bytes(_resolutionSource).length <= 200, "Resolution source too long");
        
        // Check user's USDT balance
        uint256 userBalance = usdtToken.balanceOf(msg.sender);
        require(userBalance >= marketCreationFee, "Insufficient USDT balance");
        
        // Check allowance
        uint256 allowance = usdtToken.allowance(msg.sender, address(this));
        require(allowance >= marketCreationFee, "Insufficient USDT allowance");
        
        // Collect market creation fee
        bool transferSuccess = usdtToken.transferFrom(msg.sender, address(this), marketCreationFee);
        require(transferSuccess, "USDT transfer failed");
        
        // Platform fee (20% of creation fee)
        uint256 platformFee = (marketCreationFee * 2000) / 10000;
        
        // Initial liquidity (80% of creation fee)
        uint256 initialLiquidity = marketCreationFee - platformFee;
        
        // Transfer platform fee to recipient
        if (platformFee > 0) {
            bool feeTransferSuccess = usdtToken.transfer(platformFeeRecipient, platformFee);
            require(feeTransferSuccess, "Platform fee transfer failed");
        }
        
        // Create new market
        uint256 marketId = totalMarkets + 1;
        totalMarkets = marketId;
        
        markets[marketId] = Market({
            question: _question,
            expirationTime: _expirationTime,
            creator: msg.sender,
            yesLiquidity: initialLiquidity / 2,
            noLiquidity: initialLiquidity / 2,
            state: MarketState.Active,
            resolvedSide: Side.Yes, // Default value, will be set when resolved
            resolutionSource: _resolutionSource,
            createdAt: block.timestamp,
            resolvedAt: 0,
            totalVolume: initialLiquidity,
            disputeState: DisputeState.None
        });
        
        // Add to creator's markets
        creatorMarkets[msg.sender].push(marketId);
        
        emit MarketCreated(marketId, msg.sender, _question, _expirationTime, _resolutionSource);
        
        return marketId;
    }
    
    /**
     * @dev Make a forecast on a market
     * @param _marketId Market ID
     * @param _side YES or NO
     * @param _amount Amount in USDT
     */
    function makeForecast(
        uint256 _marketId,
        Side _side,
        uint256 _amount
    ) external nonReentrant {
        require(_marketId > 0 && _marketId <= totalMarkets, "Invalid market ID");
        require(_amount > 0, "Amount must be greater than 0");
        
        Market storage market = markets[_marketId];
        require(market.state == MarketState.Active, "Market not active");
        require(block.timestamp < market.expirationTime, "Market expired");
        
        // Check if user has already forecasted in this market
        for (uint256 i = 0; i < forecasts[_marketId].length; i++) {
            if (forecasts[_marketId][i].user == msg.sender) {
                revert("Already forecasted in this market");
            }
        }
        
        // Transfer USDT from user
        require(usdtToken.transferFrom(msg.sender, address(this), _amount), "USDT transfer failed");
        
        // Update market liquidity
        if (_side == Side.Yes) {
            market.yesLiquidity += _amount;
        } else {
            market.noLiquidity += _amount;
        }
        
        // Update total volume
        market.totalVolume += _amount;
        
        // Store forecast
        forecasts[_marketId].push(Forecast({
            user: msg.sender,
            marketId: _marketId,
            side: _side,
            amount: _amount,
            timestamp: block.timestamp,
            claimed: false
        }));
        
        // Add to user's markets
        bool userHasMarket = false;
        for (uint256 i = 0; i < userMarkets[msg.sender].length; i++) {
            if (userMarkets[msg.sender][i] == _marketId) {
                userHasMarket = true;
                break;
            }
        }
        
        if (!userHasMarket) {
            userMarkets[msg.sender].push(_marketId);
        }
        
        emit ForecastMade(_marketId, msg.sender, _side, _amount);
    }
    

    function getMarket(uint256 _marketId) external view returns (
        string memory question,
        uint256 expirationTime,
        address creator,
        uint256 yesLiquidity,
        uint256 noLiquidity,
        MarketState state,
        Side resolvedSide,
        string memory resolutionSource,
        uint256 createdAt,
        uint256 resolvedAt,
        uint256 totalVolume,
        DisputeState disputeState
    ) {
        require(_marketId > 0 && _marketId <= totalMarkets, "Invalid market ID");
        
        Market memory market = markets[_marketId];
        
        return (
            market.question,
            market.expirationTime,
            market.creator,
            market.yesLiquidity,
            market.noLiquidity,
            market.state,
            market.resolvedSide,
            market.resolutionSource,
            market.createdAt,
            market.resolvedAt,
            market.totalVolume,
            market.disputeState
        );
    }
    
    // Helper functions for debugging
    function getMarketCreationRequirements(address user) external view returns (
        uint256 requiredFee,
        uint256 userBalance,
        uint256 userAllowance,
        address tokenAddress,
        address feeRecipient,
        bool canCreateMarket
    ) {
        requiredFee = marketCreationFee;
        userBalance = usdtToken.balanceOf(user);
        userAllowance = usdtToken.allowance(user, address(this));
        tokenAddress = address(usdtToken);
        feeRecipient = platformFeeRecipient;
        canCreateMarket = userBalance >= requiredFee && userAllowance >= requiredFee;
    }
    
 
    function updatePlatformFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient address");
        platformFeeRecipient = _recipient;
    }

    

    
    /**
     * @dev Update reward pool percentage
     * @param _percentage New percentage in basis points
     */
    function updateRewardPoolPercentage(uint256 _percentage) external onlyOwner {
        require(platformFeePercentage + _percentage + creatorRewardPoolPercentage == 10000, "Percentages must sum to 100%");
        rewardPoolPercentage = _percentage;
    }
    
    /**
     * @dev Update creator reward pool percentage
     * @param _percentage New percentage in basis points
     */
    function updateCreatorRewardPoolPercentage(uint256 _percentage) external onlyOwner {
        require(platformFeePercentage + rewardPoolPercentage + _percentage == 10000, "Percentages must sum to 100%");
        creatorRewardPoolPercentage = _percentage;
    }
    

    /**
     * @dev Update ForecastPoints contract
     * @param _forecastPoints New ForecastPoints contract address
     */
    function updateForecastPointsContract(ForecastPoints _forecastPoints) external onlyOwner {
        forecastPoints = _forecastPoints;
    }
    
    /**
     * @dev Calculate week number
     * @param _timestamp Timestamp to calculate week number for
     * @return Week number
     */
    function getWeekNumber(uint256 _timestamp) public pure returns (uint256) {
        // Use Unix epoch (Jan 1, 1970) as the reference point
        uint256 secondsPerWeek = 7 * 24 * 60 * 60;
        return _timestamp / secondsPerWeek;
    }
    
    /**
     * @dev Get current week number
     * @return Current week number
     */
    function getCurrentWeek() external view returns (uint256) {
        return getWeekNumber(block.timestamp);
    }
    
    /**
     * @dev Recover ERC20 tokens
     * @param _token Token address
     * @param _amount Amount to recover
     */
    function recoverERC20(IERC20 _token, uint256 _amount) external onlyOwner {
        require(_token != usdtToken || _amount <= (_token.balanceOf(address(this)) - getTotalActiveLiquidity()), "Cannot recover active liquidity");
        require(_token.transfer(owner(), _amount), "Transfer failed");
    }
    
    /**
     * @dev Get total active liquidity
     * @return Total liquidity
     */
    function getTotalActiveLiquidity() public view returns (uint256) {
        uint256 total = 0;
        
        for (uint256 i = 1; i <= totalMarkets; i++) {
            Market storage market = markets[i];
            if (market.state == MarketState.Active || market.state == MarketState.Expired) {
                total += market.yesLiquidity + market.noLiquidity;
            }
        }
        
        return total;
    }
    
    /**
     * @dev Dispute a market resolution
     * @param _marketId Market ID
     * @param _reason Reason for dispute
     */
    function disputeMarketResolution(uint256 _marketId, string memory _reason) external {
        require(_marketId > 0 && _marketId <= totalMarkets, "Invalid market ID");
        
        Market storage market = markets[_marketId];
        require(market.state == MarketState.Resolved, "Market not resolved");
        require(market.disputeState == DisputeState.None, "Dispute already exists");
        require(block.timestamp <= market.resolvedAt + 3 days, "Dispute period ended");
        
        // Check if disputer has participated in the market
        bool participated = false;
        for (uint256 i = 0; i < forecasts[_marketId].length; i++) {
            if (forecasts[_marketId][i].user == msg.sender) {
                participated = true;
                break;
            }
        }
        
        require(participated || msg.sender == owner(), "Not a participant or owner");
        
        // Mark market as disputed
        market.disputeState = DisputeState.Pending;
        
        emit MarketDisputed(_marketId, msg.sender, _reason);
    }
    
    /**
     * @dev Resolve a market dispute
     * @param _marketId Market ID
     * @param _upheld Whether dispute is upheld
     * @param _newResolvedSide New resolved side if dispute is upheld
     */
    function resolveDispute(uint256 _marketId, bool _upheld, Side _newResolvedSide) external onlyOwner {
        require(_marketId > 0 && _marketId <= totalMarkets, "Invalid market ID");
        
        Market storage market = markets[_marketId];
        require(market.state == MarketState.Resolved, "Market not resolved");
        require(market.disputeState == DisputeState.Pending, "No pending dispute");
        
        market.disputeState = DisputeState.Resolved;
        
        if (_upheld) {
            // Change the resolved side
            market.resolvedSide = _newResolvedSide;
        }
        
        emit DisputeResolved(_marketId, _upheld, msg.sender);
    }

    // Add these to SpreadMarket.sol
function getMarketQuestion(uint256 marketId) external view returns (string memory) {
    return markets[marketId].question;
}

function getMarketCreator(uint256 marketId) external view returns (address) {
    return markets[marketId].creator;
}

function getMarketExpirationTime(uint256 marketId) external view returns (uint256) {
    return markets[marketId].expirationTime;
}

function getMarketLiquidity(uint256 marketId) external view returns (uint256 yes, uint256 no) {
    return (markets[marketId].yesLiquidity, markets[marketId].noLiquidity);
}

function getMarketState(uint256 marketId) external view returns (MarketState) {
    return markets[marketId].state;
}

function getMarketResolvedSide(uint256 marketId) external view returns (Side) {
    return markets[marketId].resolvedSide;
}

function getMarketResolutionSource(uint256 marketId) external view returns (string memory) {
    return markets[marketId].resolutionSource;
}

function getMarketCreatedAt(uint256 marketId) external view returns (uint256) {
    return markets[marketId].createdAt;
}

function getMarketResolvedAt(uint256 marketId) external view returns (uint256) {
    return markets[marketId].resolvedAt;
}

function getMarketTotalVolume(uint256 marketId) external view returns (uint256) {
    return markets[marketId].totalVolume;
}

function getMarketDisputeState(uint256 marketId) external view returns (DisputeState) {
    return markets[marketId].disputeState;
}
}