// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title RewardDistributor
 * @dev Handles the weekly distribution of rewards to top forecasters and creators
 */
contract RewardDistributor is Ownable, ReentrancyGuard {
    // USDT token interface
    IERC20 public usdtToken;
    
    // SpreadMarket contract interface
    address public spreadMarketContract;
    
    // Reward distribution percentages for forecasters
    uint256[10] public forecastersRewardPercentages = [
        3000, // 30.0% for 1st place
        2000, // 20.0% for 2nd place
        1500, // 15.0% for 3rd place
        500,  // 5.0% for 4th place
        500,  // 5.0% for 5th place
        500,  // 5.0% for 6th place
        500,  // 5.0% for 7th place
        500,  // 5.0% for 8th place
        500,  // 5.0% for 9th place
        500   // 5.0% for 10th place
    ];
    
    // Weekly reward pools
    mapping(uint256 => WeeklyRewardPool) public weeklyRewardPools;
    
    // Structure to track weekly reward pools
    struct WeeklyRewardPool {
        uint256 forecasterRewardPool; // Total reward pool for forecasters
        uint256 creatorRewardPool;    // Total reward pool for creators
        bool distributed;             // Whether rewards have been distributed
        uint256 distributedAt;        // Timestamp when rewards were distributed
    }
    
    // User ranking data
    struct UserRanking {
        address user;
        uint256 points;
        uint256 rank;
    }
    
    // Creator ranking data
    struct CreatorRanking {
        address creator;
        uint256 volume;
        uint256 rank;
    }
    
    // Top forecasters by week
    mapping(uint256 => UserRanking[]) public weeklyTopForecasters;
    
    // Top creators by week
    mapping(uint256 => CreatorRanking[]) public weeklyTopCreators;
    
    // Events
    event WeeklyRewardPoolsSet(uint256 indexed weekNumber, uint256 forecasterRewardPool, uint256 creatorRewardPool);
    event TopForecastersSet(uint256 indexed weekNumber, address[] forecasters, uint256[] points);
    event TopCreatorsSet(uint256 indexed weekNumber, address[] creators, uint256[] volumes);
    event WeeklyRewardsDistributed(uint256 indexed weekNumber, uint256 totalReward, address[] forecasterAddresses, uint256[] forecasterRewards, address[] creatorAddresses, uint256[] creatorRewards);
    
    /**
     * @dev Constructor
     * @param _usdtToken USDT token contract address
     * @param _spreadMarketContract SpreadMarket contract address
     */
constructor(
    IERC20 _usdtToken, 
    address _spreadMarketContract,
    address _initialOwner
) Ownable(_initialOwner) {
    usdtToken = _usdtToken;
    spreadMarketContract = _spreadMarketContract;
}
    
    /**
     * @dev Set weekly reward pools
     * @param _weekNumber Week number
     * @param _forecasterRewardPool Total reward pool for forecasters
     * @param _creatorRewardPool Total reward pool for creators
     */
    function setWeeklyRewardPools(
        uint256 _weekNumber,
        uint256 _forecasterRewardPool,
        uint256 _creatorRewardPool
    ) external onlyOwner {
        require(!weeklyRewardPools[_weekNumber].distributed, "Rewards already distributed");
        
        weeklyRewardPools[_weekNumber] = WeeklyRewardPool({
            forecasterRewardPool: _forecasterRewardPool,
            creatorRewardPool: _creatorRewardPool,
            distributed: false,
            distributedAt: 0
        });
        
        emit WeeklyRewardPoolsSet(_weekNumber, _forecasterRewardPool, _creatorRewardPool);
    }
    
    /**
     * @dev Set top forecasters for a week
     * @param _weekNumber Week number
     * @param _forecasters Array of top forecaster addresses
     * @param _points Array of forecaster points
     */
    function setTopForecasters(
        uint256 _weekNumber,
        address[] calldata _forecasters,
        uint256[] calldata _points
    ) external onlyOwner {
        require(_forecasters.length == _points.length, "Array length mismatch");
        require(_forecasters.length <= 10, "Too many forecasters");
        require(!weeklyRewardPools[_weekNumber].distributed, "Rewards already distributed");
        
        // Clear previous data
        delete weeklyTopForecasters[_weekNumber];
        
        // Add new rankings
        for (uint256 i = 0; i < _forecasters.length; i++) {
            weeklyTopForecasters[_weekNumber].push(UserRanking({
                user: _forecasters[i],
                points: _points[i],
                rank: i + 1 // Rank is 1-based
            }));
        }
        
        emit TopForecastersSet(_weekNumber, _forecasters, _points);
    }
    
    /**
     * @dev Set top creators for a week
     * @param _weekNumber Week number
     * @param _creators Array of top creator addresses
     * @param _volumes Array of creator volumes
     */
    function setTopCreators(
        uint256 _weekNumber,
        address[] calldata _creators,
        uint256[] calldata _volumes
    ) external onlyOwner {
        require(_creators.length == _volumes.length, "Array length mismatch");
        require(_creators.length <= 10, "Too many creators");
        require(!weeklyRewardPools[_weekNumber].distributed, "Rewards already distributed");
        
        // Clear previous data
        delete weeklyTopCreators[_weekNumber];
        
        // Add new rankings
        for (uint256 i = 0; i < _creators.length; i++) {
            weeklyTopCreators[_weekNumber].push(CreatorRanking({
                creator: _creators[i],
                volume: _volumes[i],
                rank: i + 1 // Rank is 1-based
            }));
        }
        
        emit TopCreatorsSet(_weekNumber, _creators, _volumes);
    }
    
    /**
     * @dev Distribute weekly rewards to top forecasters and creators
     * @param _weekNumber Week number
     */
    function distributeWeeklyRewards(uint256 _weekNumber) external onlyOwner nonReentrant {
        WeeklyRewardPool storage rewardPool = weeklyRewardPools[_weekNumber];
        require(!rewardPool.distributed, "Rewards already distributed");
        require(rewardPool.forecasterRewardPool > 0 || rewardPool.creatorRewardPool > 0, "No rewards to distribute");
        
        // Forecasters rewards
        address[] memory forecasterAddresses;
        uint256[] memory forecasterRewards;
        
        if (rewardPool.forecasterRewardPool > 0 && weeklyTopForecasters[_weekNumber].length > 0) {
            (forecasterAddresses, forecasterRewards) = distributeForecasterRewards(_weekNumber);
        } else {
            forecasterAddresses = new address[](0);
            forecasterRewards = new uint256[](0);
        }
        
        // Creators rewards
        address[] memory creatorAddresses;
        uint256[] memory creatorRewards;
        
        if (rewardPool.creatorRewardPool > 0 && weeklyTopCreators[_weekNumber].length > 0) {
            (creatorAddresses, creatorRewards) = distributeCreatorRewards(_weekNumber);
        } else {
            creatorAddresses = new address[](0);
            creatorRewards = new uint256[](0);
        }
        
        // Mark as distributed
        rewardPool.distributed = true;
        rewardPool.distributedAt = block.timestamp;
        
        uint256 totalReward = rewardPool.forecasterRewardPool + rewardPool.creatorRewardPool;
        
        emit WeeklyRewardsDistributed(
            _weekNumber,
            totalReward,
            forecasterAddresses,
            forecasterRewards,
            creatorAddresses,
            creatorRewards
        );
    }
    
    /**
     * @dev Distribute rewards to top forecasters
     * @param _weekNumber Week number
     * @return addresses Array of forecaster addresses
     * @return rewards Array of reward amounts
     */
    function distributeForecasterRewards(uint256 _weekNumber) internal returns (address[] memory addresses, uint256[] memory rewards) {
        uint256 forecasterCount = weeklyTopForecasters[_weekNumber].length;
        WeeklyRewardPool storage rewardPool = weeklyRewardPools[_weekNumber];
        
        addresses = new address[](forecasterCount);
        rewards = new uint256[](forecasterCount);
        
        for (uint256 i = 0; i < forecasterCount; i++) {
            UserRanking storage ranking = weeklyTopForecasters[_weekNumber][i];
            addresses[i] = ranking.user;
            
            // Calculate reward percentage based on rank
            uint256 percentage = i < forecastersRewardPercentages.length
                ? forecastersRewardPercentages[i]
                : 0;
            
            // Calculate reward amount
            rewards[i] = (rewardPool.forecasterRewardPool * percentage) / 10000;
            
            // Transfer USDT
            if (rewards[i] > 0) {
                require(usdtToken.transfer(ranking.user, rewards[i]), "USDT transfer failed");
            }
        }
        
        return (addresses, rewards);
    }
    
    /**
     * @dev Distribute rewards to top creators
     * @param _weekNumber Week number
     * @return addresses Array of creator addresses
     * @return rewards Array of reward amounts
     */
    function distributeCreatorRewards(uint256 _weekNumber) internal returns (address[] memory addresses, uint256[] memory rewards) {
        uint256 creatorCount = weeklyTopCreators[_weekNumber].length;
        WeeklyRewardPool storage rewardPool = weeklyRewardPools[_weekNumber];
        
        addresses = new address[](creatorCount);
        rewards = new uint256[](creatorCount);
        
        // Calculate total volume for proportional distribution
        uint256 totalVolume = 0;
        for (uint256 i = 0; i < creatorCount; i++) {
            totalVolume += weeklyTopCreators[_weekNumber][i].volume;
        }
        
        for (uint256 i = 0; i < creatorCount; i++) {
            CreatorRanking storage ranking = weeklyTopCreators[_weekNumber][i];
            addresses[i] = ranking.creator;
            
            // Calculate reward amount proportional to volume
            rewards[i] = totalVolume > 0
                ? (rewardPool.creatorRewardPool * ranking.volume) / totalVolume
                : 0;
            
            // Transfer USDT
            if (rewards[i] > 0) {
                require(usdtToken.transfer(ranking.creator, rewards[i]), "USDT transfer failed");
            }
        }
        
        return (addresses, rewards);
    }
    
    /**
     * @dev Get top forecasters for a week
     * @param _weekNumber Week number
     * @return Array of user rankings
     */
    function getTopForecasters(uint256 _weekNumber) external view returns (UserRanking[] memory) {
        return weeklyTopForecasters[_weekNumber];
    }
    
    /**
     * @dev Get top creators for a week
     * @param _weekNumber Week number
     * @return Array of creator rankings
     */
    function getTopCreators(uint256 _weekNumber) external view returns (CreatorRanking[] memory) {
        return weeklyTopCreators[_weekNumber];
    }
    
    /**
     * @dev Update forecasters reward percentages
     * @param _percentages New reward percentages array
     */
    function updateForecastersRewardPercentages(uint256[10] calldata _percentages) external onlyOwner {
        // Verify total is 100%
        uint256 total = 0;
        for (uint256 i = 0; i < _percentages.length; i++) {
            total += _percentages[i];
        }
        require(total == 10000, "Total must be 100%");
        
        forecastersRewardPercentages = _percentages;
    }
    
    /**
     * @dev Update USDT token address
     * @param _usdtToken New USDT token address
     */
    function updateUsdtToken(IERC20 _usdtToken) external onlyOwner {
        usdtToken = _usdtToken;
    }
    
    /**
     * @dev Update SpreadMarket contract address
     * @param _spreadMarketContract New SpreadMarket contract address
     */
    function updateSpreadMarketContract(address _spreadMarketContract) external onlyOwner {
        spreadMarketContract = _spreadMarketContract;
    }
    
    /**
     * @dev Get current weekly reward pool status
     * @param _weekNumber Week number
     * @return forecasterRewardPool Total reward pool for forecasters
     * @return creatorRewardPool Total reward pool for creators
     * @return distributed Whether rewards have been distributed
     * @return distributedAt Timestamp when rewards were distributed
     */
    function getWeeklyRewardPoolStatus(uint256 _weekNumber) external view returns (
        uint256 forecasterRewardPool,
        uint256 creatorRewardPool,
        bool distributed,
        uint256 distributedAt
    ) {
        WeeklyRewardPool memory pool = weeklyRewardPools[_weekNumber];
        return (
            pool.forecasterRewardPool,
            pool.creatorRewardPool,
            pool.distributed,
            pool.distributedAt
        );
    }
    
    /**
     * @dev Recover any ERC20 tokens accidentally sent to this contract
     * @param _token ERC20 token address
     * @param _amount Amount to recover
     */
    function recoverERC20(IERC20 _token, uint256 _amount) external onlyOwner {
        require(_token.transfer(owner(), _amount), "Token transfer failed");
    }
}