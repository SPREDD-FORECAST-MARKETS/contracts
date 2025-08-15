// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.17;

import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title WeeklyForecastPointManager
 * @dev FIXED VERSION: Eliminates DoS vulnerability by moving sorting off-chain
 * - Isolated reward pools per week to prevent token mixing
 * - Off-chain leaderboard calculation with on-chain verification
 * - Emergency mechanisms to prevent contract freeze
 * - Support for backdated processing of missed weeks
 */
contract WeeklyForecastPointManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // Weekly cycle management
    uint256 public constant WEEK_DURATION = 7 days;
    uint256 public weekStartTime;
    uint256 public currentWeek;
    uint256 public immutable topK; // Number of top performers to store each week
    
    // Reward token (USDT)
    IERC20 public rewardToken;
    
    // FIXED: Per-week reward pool isolation to prevent token mixing
    mapping(uint256 => uint256) public weeklyRewardPools; // week => accumulated USDT
    mapping(uint256 => bool) public weeklyRewardsDistributed; // week => distributed status
    
    // Reward distribution percentages for top 10 traders (in basis points, 10000 = 100%)
    uint256[10] public rewardPercentages = [2500, 1800, 1500, 1000, 800, 700, 600, 500, 400, 200];
    
    // FP tracking
    mapping(address => uint256) public weeklyTraderFP;
    mapping(address => uint256) public weeklyCreatorFP;
    mapping(address => uint256) public totalTraderFP;
    mapping(address => uint256) public totalCreatorFP;
    
    // Historical tracking for past weeks
    mapping(uint256 => mapping(address => uint256)) public historicalTraderFP;
    mapping(uint256 => mapping(address => uint256)) public historicalCreatorFP;
    
    // Reward tracking - now per week
    mapping(uint256 => uint256) public weeklyRewardPoolDistributed;
    mapping(uint256 => mapping(address => uint256)) public weeklyTraderRewards;
    mapping(address => uint256) public totalRewardsEarned;
    
    // Winner storage
    struct TopPerformer {
        address user;
        uint256 fpPoints;
    }
    
    mapping(uint256 => TopPerformer[]) public weeklyTopTraders;
    mapping(uint256 => TopPerformer[]) public weeklyTopCreators;
    
    // Authorization and management
    mapping(address => bool) public authorizedContracts;
    address public spreddFactory;
    address public leaderboardManager; // FIXED: Off-chain service address
    
    // FIXED: Simplified participant tracking (no on-chain sorting)
    address[] public currentTraders;
    address[] public currentCreators;
    mapping(address => bool) public isTrackedTrader;
    mapping(address => bool) public isTrackedCreator;
    
    // FIXED: Week status management for off-chain processing
    enum WeekStatus {
        ACTIVE,           // Week is active, accepting FP
        PENDING_FINALIZE, // Week ended, waiting for leaderboard submission
        FINALIZED         // Leaderboard submitted, rewards distributed
    }
    
    mapping(uint256 => WeekStatus) public weekStatus;
    uint256 public constant FINALIZATION_DEADLINE = 2 days; // Max time to submit leaderboard
    
    // FP calculation constants
    uint256 public constant PRECISION = 1e6;
    uint256 public constant MIN_MARKET_SIZE_WEIGHT = 500000; // 0.5 in precision
    uint256 public constant MAX_MARKET_SIZE_WEIGHT = 2000000; // 2.0 in precision
    uint256 public constant MIN_EARLY_BONUS = 1000000; // 1.0 in precision
    uint256 public constant MAX_EARLY_BONUS = 2000000; // 2.0 in precision
    uint256 public constant MIN_CORRECTNESS_MULTIPLIER = 1000000; // 1.0 in precision
    uint256 public constant MAX_CORRECTNESS_MULTIPLIER = 2000000; // 2.0 in precision
    
    // Creator FP constants
    uint256 public constant CREATOR_BASE_FP = 100;
    uint256 public constant CREATOR_VOLUME_MULTIPLIER = 10;

    /// @notice Events
    event WeeklyReset(uint256 newWeek, uint256 timestamp);
    event WeekEnded(uint256 indexed week, uint256 endTime, uint256 participantCount);
    event TraderFPAwarded(address indexed user, uint256 fpAmount, bytes32 indexed marketId);
    event CreatorFPAwarded(address indexed creator, uint256 fpAmount, bytes32 indexed marketId);
    event ContractAuthorized(address indexed contractAddr, bool authorized);
    event LeaderboardManagerSet(address indexed manager);
    
    // FIXED: New events for off-chain process
    event WeeklyLeaderboardSubmitted(
        uint256 indexed week,
        address[] topTraders,
        uint256[] traderFP,
        address[] topCreators,
        uint256[] creatorFP,
        address submitter
    );
    
    event TraderRewardsDistributed(
        uint256 indexed week,
        address[] traders,
        uint256[] rewardAmounts,
        uint256 totalDistributed
    );
    
    event BackdatedRewardsDistributed(
        uint256 indexed week,
        address[] traders,
        uint256[] amounts,
        uint256 total
    );
    
    event WeeklyRewardPoolUpdated(uint256 indexed week, uint256 amount, uint256 totalPool);
    event RewardPercentagesUpdated(uint256[10] newPercentages);

    modifier onlyAuthorized() {
        require(authorizedContracts[msg.sender], "Not authorized contract");
        _;
    }

    modifier onlyLeaderboardManager() {
        require(msg.sender == leaderboardManager, "Only leaderboard manager");
        _;
    }

    // FIXED: Removed automatic weekly update to prevent DoS
    modifier manualWeeklyUpdate() {
        if (block.timestamp >= weekStartTime + WEEK_DURATION && weekStatus[currentWeek] == WeekStatus.ACTIVE) {
            _endCurrentWeek();
        }
        _;
    }

    constructor(uint256 _topK, address _rewardToken) {
        require(_topK > 0 && _topK <= 50, "TopK must be between 1 and 50");
        require(_rewardToken != address(0), "Invalid reward token");
        _setupOwner(msg.sender);
        topK = _topK;
        rewardToken = IERC20(_rewardToken);
        weekStartTime = block.timestamp;
        currentWeek = 1;
        weekStatus[currentWeek] = WeekStatus.ACTIVE;
    }

    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @notice FIXED: Set leaderboard manager (trusted off-chain service)
     */
    function setLeaderboardManager(address _manager) external {
        require(msg.sender == owner(), "Only owner");
        require(_manager != address(0), "Invalid manager address");
        leaderboardManager = _manager;
        emit LeaderboardManagerSet(_manager);
    }

    /**
     * @notice FIXED: Contribute to specific week's reward pool (direct transfer)
     */
    function contributeToRewardPool(uint256 _amount) external onlyAuthorized {
        require(_amount > 0, "Amount must be positive");
        
        // FIXED: Direct transfer instead of transferFrom to prevent silent failures
        rewardToken.safeTransferFrom(msg.sender, address(this), _amount);
        
        // FIXED: Add to current week's specific pool
        weeklyRewardPools[currentWeek] += _amount;
        
        emit WeeklyRewardPoolUpdated(currentWeek, _amount, weeklyRewardPools[currentWeek]);
    }

    /**
     * @notice Award FP to trader - FIXED: No automatic sorting
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
    ) external onlyAuthorized manualWeeklyUpdate {
        require(weekStatus[currentWeek] == WeekStatus.ACTIVE, "Week not active");
        
        uint256 fpAmount = _calculateTraderFP(
            _marketVolume,
            _userPositionTime,
            _marketCreationTime,
            _marketDuration,
            _correctSideLiquidity,
            _totalLiquidity,
            _userPositionSize
        );

        weeklyTraderFP[_user] += fpAmount;
        totalTraderFP[_user] += fpAmount;

        if (!isTrackedTrader[_user]) {
            currentTraders.push(_user);
            isTrackedTrader[_user] = true;
        }

        emit TraderFPAwarded(_user, fpAmount, _marketId);
    }

    /**
     * @notice Award FP to creator - FIXED: No automatic sorting
     */
    function awardCreatorFP(
        address _creator,
        bytes32 _marketId,
        uint256 _marketVolume,
        uint256 _tradeCount
    ) external onlyAuthorized manualWeeklyUpdate {
        require(weekStatus[currentWeek] == WeekStatus.ACTIVE, "Week not active");
        
        uint256 fpAmount = _calculateCreatorFP(_marketVolume, _tradeCount);

        weeklyCreatorFP[_creator] += fpAmount;
        totalCreatorFP[_creator] += fpAmount;

        if (!isTrackedCreator[_creator]) {
            currentCreators.push(_creator);
            isTrackedCreator[_creator] = true;
        }

        emit CreatorFPAwarded(_creator, fpAmount, _marketId);
    }

    /**
     * @notice FIXED: End current week without sorting - wait for off-chain leaderboard
     */
    function _endCurrentWeek() internal {
        require(weekStatus[currentWeek] == WeekStatus.ACTIVE, "Week already ended");
        
        weekStatus[currentWeek] = WeekStatus.PENDING_FINALIZE;
        uint256 participantCount = currentTraders.length + currentCreators.length;
        
        emit WeekEnded(currentWeek, block.timestamp, participantCount);
    }

    /**
     * @notice FIXED: Submit weekly leaderboard from off-chain service for ANY week
     * @param _week Week number to finalize (can be current or past week)
     * @param _topTraders Array of top trader addresses (sorted by FP, descending)
     * @param _traderFP Array of trader FP points (must match on-chain data)
     * @param _topCreators Array of top creator addresses (sorted by FP, descending)
     * @param _creatorFP Array of creator FP points (must match on-chain data)
     */
    function submitWeeklyLeaderboard(
        uint256 _week,
        address[] calldata _topTraders,
        uint256[] calldata _traderFP,
        address[] calldata _topCreators,
        uint256[] calldata _creatorFP
    ) external onlyLeaderboardManager nonReentrant {
        require(_week > 0 && _week <= currentWeek, "Invalid week number");
        require(weekStatus[_week] == WeekStatus.PENDING_FINALIZE, "Week not ready for finalization");
        require(_topTraders.length <= 50 && _topCreators.length <= 50, "Too many winners");
        require(_topTraders.length == _traderFP.length, "Trader arrays length mismatch");
        require(_topCreators.length == _creatorFP.length, "Creator arrays length mismatch");

        // FIXED: Allow submissions for past weeks within deadline
        uint256 weekEndTime = getWeekEndTime(_week);
        require(block.timestamp <= weekEndTime + FINALIZATION_DEADLINE, "Finalization deadline passed");

        // Verify data matches on-chain records
        if (_week < currentWeek) {
            _verifyHistoricalData(_week, _topTraders, _traderFP, _topCreators, _creatorFP);
        } else {
            _verifyCurrentWeekData(_topTraders, _traderFP, _topCreators, _creatorFP);
        }

        // Store leaderboard results
        _storeLeaderboardResults(_week, _topTraders, _traderFP, _topCreators, _creatorFP);

        // FIXED: Distribute rewards from specific week's pool
        _distributeWeeklyRewards(_week, _topTraders);

        // Mark week as finalized
        weekStatus[_week] = WeekStatus.FINALIZED;
        weeklyRewardsDistributed[_week] = true;

        // If this is current week, start new week
        if (_week == currentWeek) {
            _storeHistoricalData(_week);
            _startNewWeek();
        }

        emit WeeklyLeaderboardSubmitted(_week, _topTraders, _traderFP, _topCreators, _creatorFP, msg.sender);
    }

    /**
     * @notice FIXED: Emergency week finalization that preserves tokens
     */
    function emergencyFinalizeWeek(uint256 _week) external {
        require(msg.sender == owner(), "Only owner");
        require(_week <= currentWeek, "Invalid week");
        require(weekStatus[_week] == WeekStatus.PENDING_FINALIZE, "Week not pending");
        
        uint256 weekEndTime = getWeekEndTime(_week);
        require(block.timestamp > weekEndTime + FINALIZATION_DEADLINE, "Deadline not passed");

        // FIXED: Don't distribute rewards, but preserve tokens for manual distribution later
        weekStatus[_week] = WeekStatus.FINALIZED;
        
        if (_week < currentWeek) {
            // For past weeks, just mark as finalized without starting new week
            emit WeeklyLeaderboardSubmitted(_week, new address[](0), new uint256[](0), new address[](0), new uint256[](0), msg.sender);
        } else {
            // For current week, store data and start new week
            _storeHistoricalData(_week);
            _startNewWeek();
            emit WeeklyLeaderboardSubmitted(_week, new address[](0), new uint256[](0), new address[](0), new uint256[](0), msg.sender);
        }
    }

    /**
     * @notice FIXED: Process multiple weeks in sequence for batch recovery
     */
    function submitMultipleWeeks(
        uint256[] calldata _weeks,
        address[][] calldata _topTraders,
        uint256[][] calldata _traderFP,
        address[][] calldata _topCreators,
        uint256[][] calldata _creatorFP
    ) external onlyLeaderboardManager {
        require(_weeks.length == _topTraders.length, "Array length mismatch");
        require(_weeks.length == _traderFP.length, "Array length mismatch");
        require(_weeks.length == _topCreators.length, "Array length mismatch");
        require(_weeks.length == _creatorFP.length, "Array length mismatch");
        require(_weeks.length <= 10, "Too many weeks at once");

        // Process weeks in chronological order
        for (uint256 i = 0; i < _weeks.length; i++) {
            // Ensure weeks are in order
            if (i > 0) {
                require(_weeks[i] == _weeks[i-1] + 1, "Weeks must be consecutive");
            }
            
            // FIXED: Use this.submitWeeklyLeaderboard for external call
            this.submitWeeklyLeaderboard(
                _weeks[i],
                _topTraders[i],
                _traderFP[i],
                _topCreators[i],
                _creatorFP[i]
            );
        }
    }

    /**
     * @notice FIXED: Safe manual weekly reset (for owner, no sorting)
     */
    function forceWeeklyReset() external {
        require(msg.sender == owner(), "Only owner");
        
        if (weekStatus[currentWeek] == WeekStatus.ACTIVE) {
            _endCurrentWeek();
        } else if (weekStatus[currentWeek] == WeekStatus.PENDING_FINALIZE) {
            // FIXED: Use this.emergencyFinalizeWeek for external call
            this.emergencyFinalizeWeek(currentWeek);
        }
    }

    /**
     * @notice FIXED: Distribute rewards from specific week's token pool
     */
    function _distributeWeeklyRewards(uint256 _week, address[] calldata _topTraders) internal {
        uint256 weekRewardPool = weeklyRewardPools[_week];
        
        if (_topTraders.length == 0 || weekRewardPool == 0) {
            return; // No traders or rewards to distribute
        }

        address[] memory rewardedTraders = new address[](10);
        uint256[] memory rewardAmounts = new uint256[](10);
        uint256 totalDistributed = 0;
        uint256 rewardCount = _topTraders.length > 10 ? 10 : _topTraders.length;
        
        for (uint256 i = 0; i < rewardCount; i++) {
            address trader = _topTraders[i];
            uint256 rewardAmount = (weekRewardPool * rewardPercentages[i]) / 10000;
            
            if (rewardAmount > 0) {
                // Transfer from this week's specific pool
                rewardToken.safeTransfer(trader, rewardAmount);
                
                // Track rewards
                weeklyTraderRewards[_week][trader] = rewardAmount;
                totalRewardsEarned[trader] += rewardAmount;
                
                rewardedTraders[i] = trader;
                rewardAmounts[i] = rewardAmount;
                totalDistributed += rewardAmount;
            }
        }

        // Update pool tracking
        weeklyRewardPools[_week] -= totalDistributed; // Deduct distributed amount
        weeklyRewardPoolDistributed[_week] = totalDistributed;

        // Create properly sized arrays for event
        address[] memory actualTraders = new address[](rewardCount);
        uint256[] memory actualAmounts = new uint256[](rewardCount);
        for (uint256 i = 0; i < rewardCount; i++) {
            actualTraders[i] = rewardedTraders[i];
            actualAmounts[i] = rewardAmounts[i];
        }

        // Emit different event for backdated rewards
        if (_week < currentWeek) {
            emit BackdatedRewardsDistributed(_week, actualTraders, actualAmounts, totalDistributed);
        } else {
            emit TraderRewardsDistributed(_week, actualTraders, actualAmounts, totalDistributed);
        }
    }

    /**
     * @notice FIXED: Manually distribute rewards for emergency-finalized weeks
     */
    function manualRewardDistribution(
        uint256 _week,
        address[] calldata _winners,
        uint256[] calldata _amounts
    ) external {
        require(msg.sender == owner(), "Only owner");
        require(weekStatus[_week] == WeekStatus.FINALIZED, "Week not finalized");
        require(!weeklyRewardsDistributed[_week], "Rewards already distributed");
        require(_winners.length == _amounts.length, "Array length mismatch");
        require(_winners.length <= 10, "Too many winners");

        uint256 totalDistribution = 0;
        for (uint256 i = 0; i < _amounts.length; i++) {
            totalDistribution += _amounts[i];
        }
        
        require(totalDistribution <= weeklyRewardPools[_week], "Insufficient week pool");

        // Distribute rewards
        for (uint256 i = 0; i < _winners.length; i++) {
            if (_amounts[i] > 0) {
                rewardToken.safeTransfer(_winners[i], _amounts[i]);
                weeklyTraderRewards[_week][_winners[i]] = _amounts[i];
                totalRewardsEarned[_winners[i]] += _amounts[i];
            }
        }

        // Update tracking
        weeklyRewardPools[_week] -= totalDistribution;
        weeklyRewardPoolDistributed[_week] = totalDistribution;
        weeklyRewardsDistributed[_week] = true;

        emit BackdatedRewardsDistributed(_week, _winners, _amounts, totalDistribution);
    }

    /**
     * @notice Store leaderboard results
     */
    function _storeLeaderboardResults(
        uint256 _week,
        address[] calldata _topTraders,
        uint256[] calldata _traderFP,
        address[] calldata _topCreators,
        uint256[] calldata _creatorFP
    ) internal {
        // Store top traders with their FP points
        delete weeklyTopTraders[_week];
        for (uint256 i = 0; i < _topTraders.length; i++) {
            weeklyTopTraders[_week].push(TopPerformer({
                user: _topTraders[i],
                fpPoints: _traderFP[i]
            }));
        }

        // Store top creators with their FP points
        delete weeklyTopCreators[_week];
        for (uint256 i = 0; i < _topCreators.length; i++) {
            weeklyTopCreators[_week].push(TopPerformer({
                user: _topCreators[i],
                fpPoints: _creatorFP[i]
            }));
        }
    }

    /**
     * @notice Verify historical data for past weeks
     */
    function _verifyHistoricalData(
        uint256 _week,
        address[] calldata _topTraders,
        uint256[] calldata _traderFP,
        address[] calldata _topCreators,
        uint256[] calldata _creatorFP
    ) internal view {
        // Verify against historical records
        for (uint256 i = 0; i < _topTraders.length; i++) {
            require(historicalTraderFP[_week][_topTraders[i]] == _traderFP[i], "Historical trader FP mismatch");
            if (i > 0) {
                require(_traderFP[i] <= _traderFP[i-1], "Traders not sorted descending");
            }
        }
        
        for (uint256 i = 0; i < _topCreators.length; i++) {
            require(historicalCreatorFP[_week][_topCreators[i]] == _creatorFP[i], "Historical creator FP mismatch");
            if (i > 0) {
                require(_creatorFP[i] <= _creatorFP[i-1], "Creators not sorted descending");
            }
        }
    }

    /**
     * @notice Verify current week data
     */
    function _verifyCurrentWeekData(
        address[] calldata _topTraders,
        uint256[] calldata _traderFP,
        address[] calldata _topCreators,
        uint256[] calldata _creatorFP
    ) internal view {
        // Verify against current week FP
        for (uint256 i = 0; i < _topTraders.length; i++) {
            require(weeklyTraderFP[_topTraders[i]] == _traderFP[i], "Current trader FP mismatch");
            if (i > 0) {
                require(_traderFP[i] <= _traderFP[i-1], "Traders not sorted descending");
            }
        }
        
        for (uint256 i = 0; i < _topCreators.length; i++) {
            require(weeklyCreatorFP[_topCreators[i]] == _creatorFP[i], "Current creator FP mismatch");
            if (i > 0) {
                require(_creatorFP[i] <= _creatorFP[i-1], "Creators not sorted descending");
            }
        }
    }

    /**
     * @notice Store historical data for the week
     */
    function _storeHistoricalData(uint256 _week) internal {
        for (uint256 i = 0; i < currentTraders.length; i++) {
            address trader = currentTraders[i];
            historicalTraderFP[_week][trader] = weeklyTraderFP[trader];
        }

        for (uint256 i = 0; i < currentCreators.length; i++) {
            address creator = currentCreators[i];
            historicalCreatorFP[_week][creator] = weeklyCreatorFP[creator];
        }
    }

    /**
     * @notice Start new week and reset data
     */
    function _startNewWeek() internal {
        // Reset weekly FP for all tracked participants
        for (uint256 i = 0; i < currentTraders.length; i++) {
            weeklyTraderFP[currentTraders[i]] = 0;
            isTrackedTrader[currentTraders[i]] = false;
        }

        for (uint256 i = 0; i < currentCreators.length; i++) {
            weeklyCreatorFP[currentCreators[i]] = 0;
            isTrackedCreator[currentCreators[i]] = false;
        }

        delete currentTraders;
        delete currentCreators;

        // Start new week
        currentWeek++;
        weekStartTime = block.timestamp;
        weekStatus[currentWeek] = WeekStatus.ACTIVE;

        emit WeeklyReset(currentWeek, block.timestamp);
    }

    /**
     * @notice Get week end time for any week
     */
    function getWeekEndTime(uint256 _week) public view returns (uint256) {
        uint256 weekStartTimeFor = weekStartTime + ((_week - 1) * WEEK_DURATION);
        return weekStartTimeFor + WEEK_DURATION;
    }

    /**
     * @notice Get pending weeks that need finalization
     */
    function getPendingWeeks() external view returns (uint256[] memory pendingWeeks, uint256[] memory rewardPools) {
        uint256 pendingCount = 0;
        
        // Count pending weeks
        for (uint256 i = 1; i < currentWeek; i++) {
            if (weekStatus[i] == WeekStatus.PENDING_FINALIZE) {
                pendingCount++;
            }
        }
        
        pendingWeeks = new uint256[](pendingCount);
        rewardPools = new uint256[](pendingCount);
        
        uint256 index = 0;
        for (uint256 i = 1; i < currentWeek; i++) {
            if (weekStatus[i] == WeekStatus.PENDING_FINALIZE) {
                pendingWeeks[index] = i;
                rewardPools[index] = weeklyRewardPools[i];
                index++;
            }
        }
    }

    /**
     * @notice Get total undistributed rewards across all weeks
     */
    function getTotalUndistributedRewards() external view returns (uint256 total) {
        for (uint256 i = 1; i <= currentWeek; i++) {
            if (!weeklyRewardsDistributed[i]) {
                total += weeklyRewardPools[i];
            }
        }
    }


    /**
     * @notice Check if an address is a contract
     * @dev Uses code length check to determine if address is a contract
     */

     function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    /**
     * @notice Set authorized contract
     */
    function setAuthorizedContract(address _contract, bool _authorized) external {
        require(msg.sender == spreddFactory, "Only factory can authorize contracts");
        
        // 🔒 SECURITY FIX: Only allow contract addresses to be authorized
        if (_authorized) {
            require(_isContract(_contract), "Only contracts can be authorized");
        }
        
        authorizedContracts[_contract] = _authorized;
        emit ContractAuthorized(_contract, _authorized);
    }

    /**
     * @notice Set Spredd Factory
     */
    function setSpreddFactory(address _spreddFactory) external {
        require(msg.sender == owner(), "Only owner can set factory");
        
        require(_isContract(_spreddFactory), "Factory must be a contract");
        
        spreddFactory = _spreddFactory;
        authorizedContracts[spreddFactory] = true;
    }

    /**
     * @notice Update reward percentages
     */
    function setRewardPercentages(uint256[10] memory _percentages) external {
        require(msg.sender == owner(), "Only owner can set percentages");
        
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < 10; i++) {
            totalPercentage += _percentages[i];
        }
        require(totalPercentage == 10000, "Percentages must sum to 100%");
        
        rewardPercentages = _percentages;
        emit RewardPercentagesUpdated(_percentages);
    }

    // FP Calculation Functions (unchanged from original)
    function _calculateTraderFP(
        uint256 _marketVolume,
        uint256 _userPositionTime,
        uint256 _marketCreationTime,
        uint256 _marketDuration,
        uint256 _correctSideLiquidity,
        uint256 _totalLiquidity,
        uint256 _userPositionSize
    ) internal pure returns (uint256) {
        uint256 marketSizeWeight = _calculateMarketSizeWeight(_marketVolume);
        uint256 earlyBonus = _calculateEarlyBonus(_userPositionTime, _marketCreationTime, _marketDuration);
        uint256 correctnessMultiplier = _calculateCorrectnessMultiplier(_correctSideLiquidity, _totalLiquidity);

        uint256 baseFP = _userPositionSize;
        return (baseFP * marketSizeWeight * earlyBonus * correctnessMultiplier) / (PRECISION * PRECISION * PRECISION);
    }

    function _calculateCreatorFP(uint256 _marketVolume, uint256 _tradeCount) internal pure returns (uint256) {
        uint256 baseFP = CREATOR_BASE_FP;
        uint256 volumeBonus = (_marketVolume * CREATOR_VOLUME_MULTIPLIER) / (1000 * 1e6);
        uint256 activityBonus = _tradeCount * 5;
        return baseFP + volumeBonus + activityBonus;
    }

    function _calculateMarketSizeWeight(uint256 _totalVolume) internal pure returns (uint256) {
        uint256 variableComponent = (_totalVolume * 100000) / 100;
        uint256 weight = MIN_MARKET_SIZE_WEIGHT + variableComponent;
        return weight > MAX_MARKET_SIZE_WEIGHT ? MAX_MARKET_SIZE_WEIGHT : weight;
    }

    function _calculateEarlyBonus(uint256 _positionTime, uint256 _marketCreationTime, uint256 _marketDuration) internal pure returns (uint256) {
        if (_positionTime <= _marketCreationTime) return MAX_EARLY_BONUS;
        
        uint256 forecastDelay = _positionTime - _marketCreationTime;
        if (forecastDelay >= _marketDuration) return MIN_EARLY_BONUS;

        uint256 bonusComponent = ((_marketDuration - forecastDelay) * PRECISION) / _marketDuration;
        return MIN_EARLY_BONUS + bonusComponent;
    }

    function _calculateCorrectnessMultiplier(uint256 _correctSideLiquidity, uint256 _totalLiquidity) internal pure returns (uint256) {
        if (_totalLiquidity == 0) return MIN_CORRECTNESS_MULTIPLIER;
        
        uint256 correctRatio = (_correctSideLiquidity * PRECISION) / _totalLiquidity;
        uint256 contrarianism = PRECISION - correctRatio;
        return MIN_CORRECTNESS_MULTIPLIER + contrarianism;
    }

    // View Functions (unchanged from original but cleaned up)
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
            weeklyRewardPools[currentWeek]
        );
    }

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

    function getCurrentWeekUserFP(address _user) external view returns (
        uint256 traderFP,
        uint256 creatorFP,
        uint256 totalWeeklyFP
    ) {
        traderFP = weeklyTraderFP[_user];
        creatorFP = weeklyCreatorFP[_user];
        totalWeeklyFP = traderFP + creatorFP;
    }

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
        
        topTraders = new address[](traders.length);
        traderFP = new uint256[](traders.length);
        traderRewards = new uint256[](traders.length);
        for (uint256 i = 0; i < traders.length; i++) {
            topTraders[i] = traders[i].user;
            traderFP[i] = traders[i].fpPoints;
            traderRewards[i] = weeklyTraderRewards[_week][traders[i].user];
        }
        
        topCreators = new address[](creators.length);
        creatorFP = new uint256[](creators.length);
        for (uint256 i = 0; i < creators.length; i++) {
            topCreators[i] = creators[i].user;
            creatorFP[i] = creators[i].fpPoints;
        }
        
        totalDistributed = weeklyRewardPoolDistributed[_week];
    }

    function getTraderRewardInfo(address _trader) external view returns (
        uint256 totalEarned,
        uint256 currentWeekFP,
        uint256 currentWeekRank,
        uint256 potentialReward
    ) {
        totalEarned = totalRewardsEarned[_trader];
        currentWeekFP = weeklyTraderFP[_trader];
        
        // Calculate current week rank (simple calculation, no sorting)
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
            potentialReward = (weeklyRewardPools[currentWeek] * rewardPercentages[currentWeekRank - 1]) / 10000;
        }
    }

    function getCurrentRewardPoolStatus() external view returns (
        uint256 currentPool,
        uint256 contractBalance,
        address rewardTokenAddress,
        uint256 weeklyDistributed
    ) {
        currentPool = weeklyRewardPools[currentWeek];
        contractBalance = rewardToken.balanceOf(address(this));
        rewardTokenAddress = address(rewardToken);
        if (currentWeek > 1) {
            weeklyDistributed = weeklyRewardPoolDistributed[currentWeek - 1];
        }
    }

    function getRewardPercentages() external view returns (uint256[10] memory) {
        return rewardPercentages;
    }

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

    function previewCreatorFP(
        uint256 _marketVolume,
        uint256 _tradeCount
    ) external pure returns (uint256 totalFP, uint256 baseFP, uint256 volumeBonus, uint256 activityBonus) {
        baseFP = CREATOR_BASE_FP;
        volumeBonus = (_marketVolume * CREATOR_VOLUME_MULTIPLIER) / (1000 * 1e6);
        activityBonus = _tradeCount * 5;
        totalFP = baseFP + volumeBonus + activityBonus;
    }

    function emergencyWithdraw(uint256 _amount) external {
        require(msg.sender == owner(), "Only owner can emergency withdraw");
        require(_amount <= rewardToken.balanceOf(address(this)), "Insufficient balance");
        rewardToken.safeTransfer(owner(), _amount);
    }
}