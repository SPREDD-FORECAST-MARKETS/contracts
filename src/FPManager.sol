// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title WeeklyForecastPointManager
 * @dev Manages weekly Forecast Points (FP) calculation and ranking for traders and creators
 * Accumulates USDT from market resolutions and distributes to top 10 traders weekly
 */
contract WeeklyForecastPointManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // Weekly cycle management
    uint256 public constant WEEK_DURATION = 7 days;
    uint256 public weekStartTime;
    uint256 public currentWeek;
    uint256 public immutable topK; // Number of top performers to store each week
    
    // Reward token (USDT) and accumulated pool
    IERC20 public rewardToken; // USDT token
    uint256 public currentWeekRewardPool; // Accumulated USDT for current week
    
    // Reward distribution percentages for top 10 traders (in basis points, 10000 = 100%)
    uint256[10] public rewardPercentages = [2500, 1800, 1500, 1000, 800, 700, 600, 500, 400, 200]; // 25%, 18%, 15%, 10%, 8%, 7%, 6%, 5%, 4%, 2%
    
    // Weekly FP tracking (resets every week)
    mapping(address => uint256) public weeklyTraderFP;
    mapping(address => uint256) public weeklyCreatorFP;
    
    // All-time FP tracking (never resets)
    mapping(address => uint256) public totalTraderFP;
    mapping(address => uint256) public totalCreatorFP;
    
    // Historical tracking for past weeks
    mapping(uint256 => mapping(address => uint256)) public historicalTraderFP; // week => user => FP
    mapping(uint256 => mapping(address => uint256)) public historicalCreatorFP; // week => user => FP
    
    // Weekly reward tracking
    mapping(uint256 => uint256) public weeklyRewardPoolDistributed; // week => total USDT distributed
    mapping(uint256 => mapping(address => uint256)) public weeklyTraderRewards; // week => trader => reward amount
    mapping(address => uint256) public totalRewardsEarned; // trader => total rewards earned
    
    // Top K winners storage with their FP points
    struct TopPerformer {
        address user;
        uint256 fpPoints;
    }
    
    mapping(uint256 => TopPerformer[]) public weeklyTopTraders; // week => top K traders with FP
    mapping(uint256 => TopPerformer[]) public weeklyTopCreators; // week => top K creators with FP
    
    // Authorized contracts (markets and factory)
    mapping(address => bool) public authorizedContracts;

    address public spreddFactory;

    
    // Current week leaderboard tracking
    address[] public currentTraders;
    address[] public currentCreators;
    mapping(address => bool) public isTrackedTrader;
    mapping(address => bool) public isTrackedCreator;
    
    // FP calculation constants
    uint256 public constant PRECISION = 1e6;
    uint256 public constant MIN_MARKET_SIZE_WEIGHT = 500000; // 0.5 in precision
    uint256 public constant MAX_MARKET_SIZE_WEIGHT = 2000000; // 2.0 in precision
    uint256 public constant MIN_EARLY_BONUS = 1000000; // 1.0 in precision
    uint256 public constant MAX_EARLY_BONUS = 2000000; // 2.0 in precision
    uint256 public constant MIN_CORRECTNESS_MULTIPLIER = 1000000; // 1.0 in precision
    uint256 public constant MAX_CORRECTNESS_MULTIPLIER = 2000000; // 2.0 in precision
    
    // Creator FP constants
    uint256 public constant CREATOR_BASE_FP = 100; // Base FP for creating market
    uint256 public constant CREATOR_VOLUME_MULTIPLIER = 10; // FP per 1000 USDT volume

    /// @notice Events
    event WeeklyReset(uint256 newWeek, uint256 timestamp);
    event TraderFPAwarded(address indexed user, uint256 fpAmount, bytes32 indexed marketId);
    event CreatorFPAwarded(address indexed creator, uint256 fpAmount, bytes32 indexed marketId);
    event ContractAuthorized(address indexed contractAddr, bool authorized);
    event WeeklyLeaderboardFinalized(
        uint256 week, 
        address[] topTraders, 
        uint256[] traderFP,
        address[] topCreators,
        uint256[] creatorFP
    );
    event RewardPoolContribution(
        address indexed market,
        uint256 amount,
        uint256 newPoolTotal
    );
    event TraderRewardsDistributed(
        uint256 indexed week,
        address[] indexed traders,
        uint256[] rewardAmounts,
        uint256 totalDistributed
    );
    event RewardPercentagesUpdated(uint256[10] newPercentages);

    constructor(uint256 _topK, address _rewardToken) {
        require(_topK > 0 && _topK <= 50, "TopK must be between 1 and 50");
        require(_rewardToken != address(0), "Invalid reward token");
        _setupOwner(msg.sender);
        topK = _topK;
        rewardToken = IERC20(_rewardToken);
        weekStartTime = block.timestamp;
        currentWeek = 1;
        currentWeekRewardPool = 0;
    }

    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender], "Not authorized contract");
        _;
    }

    modifier weeklyUpdate() {
        if (block.timestamp >= weekStartTime + WEEK_DURATION) {
            _processWeeklyReset();
        }
        _;
    }

    /**
     * @notice Receive USDT rewards from market contracts when they resolve
     * Called by market contracts to contribute to the reward pool
     */
    function contributeToRewardPool(uint256 _amount) external onlyAuthorized {
        require(_amount > 0, "Amount must be positive");
        
        // Transfer USDT from market to this contract
        rewardToken.safeTransferFrom(msg.sender, address(this), _amount);
        
        // Add to current week's reward pool
        currentWeekRewardPool += _amount;
        
        emit RewardPoolContribution(msg.sender, _amount, currentWeekRewardPool);
    }

    /**
     * @notice Update reward distribution percentages (only owner)
     */
    function setRewardPercentages(uint256[10] memory _percentages) external {
        require(msg.sender == owner(), "Only owner can set percentages");
        
        // Verify percentages sum to 100% (10000 basis points)
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < 10; i++) {
            totalPercentage += _percentages[i];
        }
        require(totalPercentage == 10000, "Percentages must sum to 100%");
        
        rewardPercentages = _percentages;
        emit RewardPercentagesUpdated(_percentages);
    }

    /**
     * @notice Authorize/deauthorize contracts to interact with FP manager
     */
    function setAuthorizedContract(address _contract, bool _authorized) external {
        require(msg.sender == spreddFactory, "Only factory can authorize contracts");
        authorizedContracts[_contract] = _authorized;
        emit ContractAuthorized(_contract, _authorized);
    }

    /**
     * @notice Set Spredd Factory to authorize contracts
     */
    function setSpreddFactory(address _spreddFactory) external {
        require(msg.sender == owner(), "Only owner can set factory");
        spreddFactory = _spreddFactory;
        authorizedContracts[spreddFactory] = true;
    }

    /**
     * @notice Award FP points to a trader for correct prediction
     * Called by market contracts when they resolve
     */
    function awardTraderFP(
        address _user,
        bytes32 _marketId,
        uint256 _marketVolume,
        uint256 _userPositionTime,
        uint256 _marketCreationTime,
        uint256 _marketDuration,
        uint256 _correctSideLiquidity,
        uint256 _totalLiquidity,
        uint256 _userPositionSize
    ) external onlyAuthorized weeklyUpdate {
        
        uint256 fpAmount = _calculateTraderFP(
            _marketVolume,
            _userPositionTime,
            _marketCreationTime,
            _marketDuration,
            _correctSideLiquidity,
            _totalLiquidity,
            _userPositionSize
        );

        // Award points to both weekly and total
        weeklyTraderFP[_user] += fpAmount;
        totalTraderFP[_user] += fpAmount;

        // Track user in current week leaderboard if not already tracked
        if (!isTrackedTrader[_user]) {
            currentTraders.push(_user);
            isTrackedTrader[_user] = true;
        }

        emit TraderFPAwarded(_user, fpAmount, _marketId);
    }

    /**
     * @notice Award FP points to a creator for market activity
     * Called by market contracts when trades occur
     */
    function awardCreatorFP(
        address _creator,
        bytes32 _marketId,
        uint256 _marketVolume,
        uint256 _tradeCount
    ) external onlyAuthorized weeklyUpdate {
        
        uint256 fpAmount = _calculateCreatorFP(_marketVolume, _tradeCount);

        // Award points to both weekly and total
        weeklyCreatorFP[_creator] += fpAmount;
        totalCreatorFP[_creator] += fpAmount;

        // Track creator in current week leaderboard if not already tracked
        if (!isTrackedCreator[_creator]) {
            currentCreators.push(_creator);
            isTrackedCreator[_creator] = true;
        }

        emit CreatorFPAwarded(_creator, fpAmount, _marketId);
    }

    /**
     * @notice Process weekly reset and distribute accumulated rewards to top traders
     */
    function _processWeeklyReset() internal {
        // Store historical data and get top performers before reset
        _finalizeWeeklyLeaderboard();

        // Distribute accumulated USDT rewards to top 10 traders
        _distributeTraderRewards();

        // Store historical FP for all participants
        for (uint256 i = 0; i < currentTraders.length; i++) {
            address trader = currentTraders[i];
            historicalTraderFP[currentWeek][trader] = weeklyTraderFP[trader];
        }

        for (uint256 i = 0; i < currentCreators.length; i++) {
            address creator = currentCreators[i];
            historicalCreatorFP[currentWeek][creator] = weeklyCreatorFP[creator];
        }

        // Reset weekly data
        _resetWeeklyData();

        // Start new week
        currentWeek++;
        weekStartTime = block.timestamp;
        // Reset reward pool for new week
        currentWeekRewardPool = 0;

        emit WeeklyReset(currentWeek, block.timestamp);
    }

    /**
     * @notice Distribute accumulated USDT rewards directly to top 10 traders
     */
    function _distributeTraderRewards() internal {
        TopPerformer[] memory topTraders = weeklyTopTraders[currentWeek];
        
        if (topTraders.length == 0 || currentWeekRewardPool == 0) {
            return; // No traders or rewards to distribute
        }

        address[] memory rewardedTraders = new address[](topTraders.length);
        uint256[] memory rewardAmounts = new uint256[](topTraders.length);
        uint256 totalDistributed = 0;

        // Distribute rewards according to ranking (up to top 10)
        uint256 rewardCount = topTraders.length > 10 ? 10 : topTraders.length;
        
        for (uint256 i = 0; i < rewardCount; i++) {
            address trader = topTraders[i].user;
            uint256 rewardAmount = (currentWeekRewardPool * rewardPercentages[i]) / 10000;
            
            if (rewardAmount > 0) {
                // Transfer USDT directly to trader
                rewardToken.safeTransfer(trader, rewardAmount);
                
                // Track rewards for historical purposes
                weeklyTraderRewards[currentWeek][trader] = rewardAmount;
                totalRewardsEarned[trader] += rewardAmount;
                
                rewardedTraders[i] = trader;
                rewardAmounts[i] = rewardAmount;
                totalDistributed += rewardAmount;
            }
        }

        // Store total distributed for this week
        weeklyRewardPoolDistributed[currentWeek] = totalDistributed;

        // Emit event with actual distributed amounts
        address[] memory actualTraders = new address[](rewardCount);
        uint256[] memory actualAmounts = new uint256[](rewardCount);
        
        for (uint256 i = 0; i < rewardCount; i++) {
            actualTraders[i] = rewardedTraders[i];
            actualAmounts[i] = rewardAmounts[i];
        }

        emit TraderRewardsDistributed(currentWeek, actualTraders, actualAmounts, totalDistributed);
    }

    /**
     * @notice Finalize weekly leaderboard and store top K performers with their FP
     */
    function _finalizeWeeklyLeaderboard() internal {
        // Get top K traders and creators for this week
        (address[] memory topTraders, uint256[] memory traderFPPoints) = _getTopTradersWithFP(topK);
        (address[] memory topCreators, uint256[] memory creatorFPPoints) = _getTopCreatorsWithFP(topK);

        // Store top traders with their FP points
        delete weeklyTopTraders[currentWeek];
        for (uint256 i = 0; i < topTraders.length; i++) {
            if (topTraders[i] != address(0)) {
                weeklyTopTraders[currentWeek].push(TopPerformer({
                    user: topTraders[i],
                    fpPoints: traderFPPoints[i]
                }));
            }
        }

        // Store top creators with their FP points
        delete weeklyTopCreators[currentWeek];
        for (uint256 i = 0; i < topCreators.length; i++) {
            if (topCreators[i] != address(0)) {
                weeklyTopCreators[currentWeek].push(TopPerformer({
                    user: topCreators[i],
                    fpPoints: creatorFPPoints[i]
                }));
            }
        }

        emit WeeklyLeaderboardFinalized(currentWeek, topTraders, traderFPPoints, topCreators, creatorFPPoints);
    }

    /**
     * @notice Reset weekly data
     */
    function _resetWeeklyData() internal {
        // Reset weekly FP for all tracked traders
        for (uint256 i = 0; i < currentTraders.length; i++) {
            weeklyTraderFP[currentTraders[i]] = 0;
            isTrackedTrader[currentTraders[i]] = false;
        }

        // Reset weekly FP for all tracked creators
        for (uint256 i = 0; i < currentCreators.length; i++) {
            weeklyCreatorFP[currentCreators[i]] = 0;
            isTrackedCreator[currentCreators[i]] = false;
        }

        // Clear current week arrays
        delete currentTraders;
        delete currentCreators;
    }

    /**
     * @notice Get top K traders with their FP points
     */
    function _getTopTradersWithFP(uint256 _count) internal view returns (
        address[] memory traders, 
        uint256[] memory fpPoints
    ) {
        if (currentTraders.length == 0) {
            return (new address[](0), new uint256[](0));
        }
        
        // Create arrays for sorting
        address[] memory sortedTraders = new address[](currentTraders.length);
        uint256[] memory sortedFP = new uint256[](currentTraders.length);
        
        for (uint256 i = 0; i < currentTraders.length; i++) {
            sortedTraders[i] = currentTraders[i];
            sortedFP[i] = weeklyTraderFP[currentTraders[i]];
        }

        // Simple selection sort for top K
        _selectionSort(sortedTraders, sortedFP);

        // Return top K
        uint256 resultLength = currentTraders.length > _count ? _count : currentTraders.length;
        traders = new address[](resultLength);
        fpPoints = new uint256[](resultLength);
        
        for (uint256 i = 0; i < resultLength; i++) {
            traders[i] = sortedTraders[i];
            fpPoints[i] = sortedFP[i];
        }
    }

    /**
     * @notice Get top K creators with their FP points
     */
    function _getTopCreatorsWithFP(uint256 _count) internal view returns (
        address[] memory creators, 
        uint256[] memory fpPoints
    ) {
        if (currentCreators.length == 0) {
            return (new address[](0), new uint256[](0));
        }
        
        // Create arrays for sorting
        address[] memory sortedCreators = new address[](currentCreators.length);
        uint256[] memory sortedFP = new uint256[](currentCreators.length);
        
        for (uint256 i = 0; i < currentCreators.length; i++) {
            sortedCreators[i] = currentCreators[i];
            sortedFP[i] = weeklyCreatorFP[currentCreators[i]];
        }

        // Simple selection sort for top K
        _selectionSort(sortedCreators, sortedFP);

        // Return top K
        uint256 resultLength = currentCreators.length > _count ? _count : currentCreators.length;
        creators = new address[](resultLength);
        fpPoints = new uint256[](resultLength);
        
        for (uint256 i = 0; i < resultLength; i++) {
            creators[i] = sortedCreators[i];
            fpPoints[i] = sortedFP[i];
        }
    }

    /**
     * @notice Selection sort helper (descending order)
     */
    function _selectionSort(address[] memory _addresses, uint256[] memory _values) internal pure {
        uint256 length = _addresses.length;
        
        for (uint256 i = 0; i < length - 1; i++) {
            uint256 maxIndex = i;
            
            for (uint256 j = i + 1; j < length; j++) {
                if (_values[j] > _values[maxIndex]) {
                    maxIndex = j;
                }
            }
            
            if (maxIndex != i) {
                // Swap addresses
                address tempAddr = _addresses[i];
                _addresses[i] = _addresses[maxIndex];
                _addresses[maxIndex] = tempAddr;
                
                // Swap values
                uint256 tempVal = _values[i];
                _values[i] = _values[maxIndex];
                _values[maxIndex] = tempVal;
            }
        }
    }

    /**
     * @notice Get weekly winners for a specific week with their rewards
     * @param _week The week number to query
     * @return topTraders Array of top trader addresses
     * @return traderFP Array of FP points for top traders
     * @return traderRewards Array of USDT reward amounts for top traders
     * @return topCreators Array of top creator addresses  
     * @return creatorFP Array of FP points for top creators
     * @return totalDistributed Total USDT distributed that week
     */
    function getWeeklyWinners(uint256 _week) external view returns (
        address[] memory topTraders,
        uint256[] memory traderFP,
        uint256[] memory traderRewards,
        address[] memory topCreators,
        uint256[] memory creatorFP,
        uint256 totalDistributed
    ) {
        require(_week > 0 && _week < currentWeek, "Invalid week number");
        
        TopPerformer[] memory traders = weeklyTopTraders[_week];
        TopPerformer[] memory creators = weeklyTopCreators[_week];
        
        // Extract trader data with rewards
        topTraders = new address[](traders.length);
        traderFP = new uint256[](traders.length);
        traderRewards = new uint256[](traders.length);
        for (uint256 i = 0; i < traders.length; i++) {
            topTraders[i] = traders[i].user;
            traderFP[i] = traders[i].fpPoints;
            traderRewards[i] = weeklyTraderRewards[_week][traders[i].user];
        }
        
        // Extract creator data (no rewards)
        topCreators = new address[](creators.length);
        creatorFP = new uint256[](creators.length);
        for (uint256 i = 0; i < creators.length; i++) {
            topCreators[i] = creators[i].user;
            creatorFP[i] = creators[i].fpPoints;
        }
        
        totalDistributed = weeklyRewardPoolDistributed[_week];
    }

    /**
     * @notice Get trader's reward information
     */
    function getTraderRewardInfo(address _trader) external view returns (
        uint256 totalEarned,
        uint256 currentWeekFP,
        uint256 currentWeekRank,
        uint256 potentialReward
    ) {
        totalEarned = totalRewardsEarned[_trader];
        currentWeekFP = weeklyTraderFP[_trader];
        
        // Calculate current week rank
        currentWeekRank = 0;
        uint256 traderFP = weeklyTraderFP[_trader];
        if (traderFP > 0) {
            for (uint256 i = 0; i < currentTraders.length; i++) {
                if (weeklyTraderFP[currentTraders[i]] > traderFP) {
                    currentWeekRank++;
                }
            }
            currentWeekRank++; // Convert to 1-based ranking
        }
        
        // Calculate potential reward if current rank holds
        if (currentWeekRank > 0 && currentWeekRank <= 10) {
            potentialReward = (currentWeekRewardPool * rewardPercentages[currentWeekRank - 1]) / 10000;
        }
    }

    /**
     * @notice Get current reward pool status
     */
    function getCurrentRewardPoolStatus() external view returns (
        uint256 currentPool,
        uint256 contractBalance,
        address rewardTokenAddress,
        uint256 weeklyDistributed
    ) {
        currentPool = currentWeekRewardPool;
        contractBalance = rewardToken.balanceOf(address(this));
        rewardTokenAddress = address(rewardToken);
        if (currentWeek > 1) {
            weeklyDistributed = weeklyRewardPoolDistributed[currentWeek - 1];
        }
    }

    /**
     * @notice Preview potential rewards for current week ranking
     */
    function previewCurrentWeekRewards() external view returns (
        address[] memory topTraders,
        uint256[] memory traderFP,
        uint256[] memory potentialRewards
    ) {
        (topTraders, traderFP) = _getTopTradersWithFP(10); // Get top 10
        
        potentialRewards = new uint256[](topTraders.length);
        for (uint256 i = 0; i < topTraders.length && i < 10; i++) {
            if (topTraders[i] != address(0)) {
                potentialRewards[i] = (currentWeekRewardPool * rewardPercentages[i]) / 10000;
            }
        }
    }

    /**
     * @notice Get reward distribution percentages
     */
    function getRewardPercentages() external view returns (uint256[10] memory) {
        return rewardPercentages;
    }

    /**
     * @notice Emergency withdraw (only owner)
     */
    function emergencyWithdraw(uint256 _amount) external {
        require(msg.sender == owner(), "Only owner can emergency withdraw");
        require(_amount <= rewardToken.balanceOf(address(this)), "Insufficient balance");
        
        rewardToken.safeTransfer(owner(), _amount);
    }

    // ... [Keep all the existing FP calculation and view functions unchanged]
    
    /**
     * @notice Get any user's FP points for current running week
     */
    function getCurrentWeekUserFP(address _user) external view returns (
        uint256 traderFP,
        uint256 creatorFP,
        uint256 totalWeeklyFP
    ) {
        traderFP = weeklyTraderFP[_user];
        creatorFP = weeklyCreatorFP[_user];
        totalWeeklyFP = traderFP + creatorFP;
    }

    /**
     * @notice Get user's FP points for a specific past week
     */
    function getUserWeeklyFP(address _user, uint256 _week) external view returns (
        uint256 traderFP,
        uint256 creatorFP,
        uint256 totalWeeklyFP
    ) {
        require(_week > 0 && _week < currentWeek, "Invalid week number");
        
        traderFP = historicalTraderFP[_week][_user];
        creatorFP = historicalCreatorFP[_week][_user];
        totalWeeklyFP = traderFP + creatorFP;
    }

    /**
     * @notice Get current week top performers (live leaderboard)
     */
    function getCurrentWeekTopPerformers(uint256 _count) external view returns (
        address[] memory topTraders,
        uint256[] memory traderFP,
        address[] memory topCreators,
        uint256[] memory creatorFP
    ) {
        (topTraders, traderFP) = _getTopTradersWithFP(_count);
        (topCreators, creatorFP) = _getTopCreatorsWithFP(_count);
    }

    /**
     * @notice Calculate trader FP using the three-component formula
     */
    function _calculateTraderFP(
        uint256 _marketVolume,
        uint256 _userPositionTime,
        uint256 _marketCreationTime,
        uint256 _marketDuration,
        uint256 _correctSideLiquidity,
        uint256 _totalLiquidity,
        uint256 _userPositionSize
    ) internal pure returns (uint256) {
        // Calculate FP using the three-component formula
        uint256 marketSizeWeight = _calculateMarketSizeWeight(_marketVolume);
        uint256 earlyBonus = _calculateEarlyBonus(_userPositionTime, _marketCreationTime, _marketDuration);
        uint256 correctnessMultiplier = _calculateCorrectnessMultiplier(_correctSideLiquidity, _totalLiquidity);

        // Base FP is proportional to position size
        uint256 baseFP = _userPositionSize;
        
        // Apply multipliers
        return (baseFP * marketSizeWeight * earlyBonus * correctnessMultiplier) / (PRECISION * PRECISION * PRECISION);
    }

    /**
     * @notice Calculate creator FP based on market success
     */
    function _calculateCreatorFP(
        uint256 _marketVolume,
        uint256 _tradeCount
    ) internal pure returns (uint256) {
        // Base FP for creating market
        uint256 baseFP = CREATOR_BASE_FP;
        
        // Volume bonus: 10 FP per 1000 USDT (assuming 6 decimals)
        uint256 volumeBonus = (_marketVolume * CREATOR_VOLUME_MULTIPLIER) / (1000 * 1e6);
        
        // Activity bonus: 5 FP per trade
        uint256 activityBonus = _tradeCount * 5;
        
        return baseFP + volumeBonus + activityBonus;
    }

    /**
     * @notice Calculate market size weight (0.5-2.0)
     */
    function _calculateMarketSizeWeight(uint256 _totalVolume) internal pure returns (uint256) {
        // MarketSizeWeight = MIN(2.0, 0.5 + (totalVolumeInUSDT * 0.1 / 100))
        uint256 variableComponent = (_totalVolume * 100000) / 100; // 0.1/100 = 0.001 in precision
        uint256 weight = MIN_MARKET_SIZE_WEIGHT + variableComponent;
        return weight > MAX_MARKET_SIZE_WEIGHT ? MAX_MARKET_SIZE_WEIGHT : weight;
    }

    /**
     * @notice Calculate early participation bonus (1.0-2.0)
     */
    function _calculateEarlyBonus(
        uint256 _positionTime,
        uint256 _marketCreationTime,
        uint256 _marketDuration
    ) internal pure returns (uint256) {
        if (_positionTime <= _marketCreationTime) return MAX_EARLY_BONUS;
        
        uint256 forecastDelay = _positionTime - _marketCreationTime;
        if (forecastDelay >= _marketDuration) return MIN_EARLY_BONUS;

        // EarlyBonus = 1.0 + ((marketDuration - forecastDelay) / marketDuration)
        uint256 bonusComponent = ((_marketDuration - forecastDelay) * PRECISION) / _marketDuration;
        return MIN_EARLY_BONUS + bonusComponent;
    }

    /**
     * @notice Calculate correctness multiplier (1.0-2.0)
     */
    function _calculateCorrectnessMultiplier(
        uint256 _correctSideLiquidity,
        uint256 _totalLiquidity
    ) internal pure returns (uint256) {
        if (_totalLiquidity == 0) return MIN_CORRECTNESS_MULTIPLIER;
        
        // CorrectnessMultiplier = 1.0 + (1.0 - correctSideLiquidity/totalLiquidity)
        uint256 correctRatio = (_correctSideLiquidity * PRECISION) / _totalLiquidity;
        uint256 contrarianism = PRECISION - correctRatio;
        return MIN_CORRECTNESS_MULTIPLIER + contrarianism;
    }

    /**
     * @notice Get current week info
     */
    function getCurrentWeekInfo() external view returns (
        uint256 week,
        uint256 startTime,
        uint256 endTime,
        uint256 tradersCount,
        uint256 creatorsCount,
        uint256 topKSetting,
        uint256 currentRewardPool
    ) {
        return (
            currentWeek,
            weekStartTime,
            weekStartTime + WEEK_DURATION,
            currentTraders.length,
            currentCreators.length,
            topK,
            currentWeekRewardPool
        );
    }

    /**
     * @notice Get user's all-time FP stats
     */
    function getUserAllTimeFP(address _user) external view returns (
        uint256 totalTraderFP_,
        uint256 totalCreatorFP_,
        uint256 grandTotalFP,
        uint256 totalRewardsEarned_
    ) {
        totalTraderFP_ = totalTraderFP[_user];
        totalCreatorFP_ = totalCreatorFP[_user];
        grandTotalFP = totalTraderFP_ + totalCreatorFP_;
        totalRewardsEarned_ = totalRewardsEarned[_user];
    }

    /**
     * @notice Manual weekly reset (emergency function)
     */
    function forceWeeklyReset() external {
        require(msg.sender == owner(), "Only owner can force reset");
        _processWeeklyReset();
    }

    /**
     * @notice Preview trader FP calculation (for frontend)
     */
    function previewTraderFP(
        uint256 _marketVolume,
        uint256 _userPositionTime,
        uint256 _marketCreationTime,
        uint256 _marketDuration,
        uint256 _correctSideLiquidity,
        uint256 _totalLiquidity,
        uint256 _userPositionSize
    ) external pure returns (
        uint256 totalFP,
        uint256 marketSizeWeight,
        uint256 earlyBonus,
        uint256 correctnessMultiplier
    ) {
        marketSizeWeight = _calculateMarketSizeWeight(_marketVolume);
        earlyBonus = _calculateEarlyBonus(_userPositionTime, _marketCreationTime, _marketDuration);
        correctnessMultiplier = _calculateCorrectnessMultiplier(_correctSideLiquidity, _totalLiquidity);
        
        totalFP = (_userPositionSize * marketSizeWeight * earlyBonus * correctnessMultiplier) / (PRECISION * PRECISION * PRECISION);
    }

    /**
     * @notice Preview creator FP calculation (for frontend)
     */
    function previewCreatorFP(
        uint256 _marketVolume,
        uint256 _tradeCount
    ) external pure returns (uint256 totalFP, uint256 baseFP, uint256 volumeBonus, uint256 activityBonus) {
        baseFP = CREATOR_BASE_FP;
        volumeBonus = (_marketVolume * CREATOR_VOLUME_MULTIPLIER) / (1000 * 1e6);
        activityBonus = _tradeCount * 5;
        totalFP = baseFP + volumeBonus + activityBonus;
    }
}