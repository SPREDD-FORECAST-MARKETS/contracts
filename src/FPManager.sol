// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";

/**
 * @title WeeklyForecastPointManager
 * @dev Manages weekly Forecast Points (FP) calculation and ranking for traders and creators
 * Resets every week - no reward distribution, just points and leaderboards
 */
contract WeeklyForecastPointManager is Ownable {
    
    // Weekly cycle management
    uint256 public constant WEEK_DURATION = 7 days;
    uint256 public weekStartTime;
    uint256 public currentWeek;
    uint256 public immutable topK; // Number of top performers to store each week
    
    // Weekly FP tracking (resets every week)
    mapping(address => uint256) public weeklyTraderFP;
    mapping(address => uint256) public weeklyCreatorFP;
    
    // All-time FP tracking (never resets)
    mapping(address => uint256) public totalTraderFP;
    mapping(address => uint256) public totalCreatorFP;
    
    // Historical tracking for past weeks
    mapping(uint256 => mapping(address => uint256)) public historicalTraderFP; // week => user => FP
    mapping(uint256 => mapping(address => uint256)) public historicalCreatorFP; // week => user => FP
    
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

    constructor(uint256 _topK) {
        require(_topK > 0 && _topK <= 50, "TopK must be between 1 and 50");
        _setupOwner(msg.sender);
        topK = _topK;
        weekStartTime = block.timestamp;
        currentWeek = 1;
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
     * @notice Authorize/deauthorize contracts to interact with FP manager
     */
    function setAuthorizedContract(address _contract, bool _authorized) external {
        require(msg.sender == spreddFactory, "Only owner can authorize contracts");
        authorizedContracts[_contract] = _authorized;
        emit ContractAuthorized(_contract, _authorized);
    }


    /**
     * @notice Set Spredd Factory to authorize contracts
     */
    function setSpreddFactory(address _spreddFactory) external {
        require(msg.sender == owner(), "Only owner can set factory");
        spreddFactory = _spreddFactory;
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
     * @notice Process weekly reset
     */
    function _processWeeklyReset() internal {
        // Store historical data and get top performers before reset
        _finalizeWeeklyLeaderboard();

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

        emit WeeklyReset(currentWeek, block.timestamp);
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
     * @notice Get weekly winners for a specific week
     * @param _week The week number to query
     * @return topTraders Array of top trader addresses
     * @return traderFP Array of FP points for top traders
     * @return topCreators Array of top creator addresses  
     * @return creatorFP Array of FP points for top creators
     */
    function getWeeklyWinners(uint256 _week) external view returns (
        address[] memory topTraders,
        uint256[] memory traderFP,
        address[] memory topCreators,
        uint256[] memory creatorFP
    ) {
        require(_week > 0 && _week < currentWeek, "Invalid week number");
        
        TopPerformer[] memory traders = weeklyTopTraders[_week];
        TopPerformer[] memory creators = weeklyTopCreators[_week];
        
        // Extract trader data
        topTraders = new address[](traders.length);
        traderFP = new uint256[](traders.length);
        for (uint256 i = 0; i < traders.length; i++) {
            topTraders[i] = traders[i].user;
            traderFP[i] = traders[i].fpPoints;
        }
        
        // Extract creator data
        topCreators = new address[](creators.length);
        creatorFP = new uint256[](creators.length);
        for (uint256 i = 0; i < creators.length; i++) {
            topCreators[i] = creators[i].user;
            creatorFP[i] = creators[i].fpPoints;
        }
    }

    /**
     * @notice Get any user's FP points for current running week
     * @param _user The user address to query
     * @return traderFP User's trader FP points for current week
     * @return creatorFP User's creator FP points for current week
     * @return totalWeeklyFP User's total FP points for current week
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
     * @param _user The user address to query
     * @param _week The week number to query
     * @return traderFP User's trader FP points for that week
     * @return creatorFP User's creator FP points for that week
     * @return totalWeeklyFP User's total FP points for that week
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
     * @param _count Number of top performers to return
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
        uint256 topKSetting
    ) {
        return (
            currentWeek,
            weekStartTime,
            weekStartTime + WEEK_DURATION,
            currentTraders.length,
            currentCreators.length,
            topK
        );
    }

    /**
     * @notice Get user's all-time FP stats
     */
    function getUserAllTimeFP(address _user) external view returns (
        uint256 totalTraderFP_,
        uint256 totalCreatorFP_,
        uint256 grandTotalFP
    ) {
        totalTraderFP_ = totalTraderFP[_user];
        totalCreatorFP_ = totalCreatorFP[_user];
        grandTotalFP = totalTraderFP_ + totalCreatorFP_;
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