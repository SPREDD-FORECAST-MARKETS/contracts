// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ForecastPoints
 * @dev Handles calculation of forecast points for correct predictions
 * Points are used to determine weekly leaderboard rankings
 */
contract ForecastPoints is Ownable {
    // Market states - matching SpreadMarket
    enum MarketState { Active, Expired, Resolved, Disputed }
    
    // Market sides - matching SpreadMarket
    enum Side { Yes, No }
    
    // Dispute states - matching SpreadMarket
    enum DisputeState { None, Pending, Resolved }
    
    // Forecast structure from SpreadMarket - must match exactly
    struct Forecast {
        address user;
        uint256 marketId;
        Side side;
        uint256 amount;
        uint256 timestamp;
        bool claimed;
    }
    
    // Market structure from SpreadMarket - must match exactly
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
    
    constructor(address _initialOwner) Ownable(_initialOwner) {
    }
    
    // Constants for point calculation
    uint256 public constant BASE_MULTIPLIER = 1000000; // 1.0 in fixed point
    uint256 public constant MAX_MARKET_SIZE_WEIGHT = 2000000; // 2.0 in fixed point
    uint256 public constant MIN_MARKET_SIZE_WEIGHT = 500000; // 0.5 in fixed point
    uint256 public constant MAX_EARLY_BONUS = 2000000; // 2.0 in fixed point
    uint256 public constant MIN_EARLY_BONUS = 1000000; // 1.0 in fixed point
    uint256 public constant MAX_CORRECTNESS_MULTIPLIER = 2000000; // 2.0 in fixed point
    uint256 public constant MIN_CORRECTNESS_MULTIPLIER = 1000000; // 1.0 in fixed point
    
    // Events
    event PointsParametersUpdated();
    
    /**
     * @dev Calculate forecast points with detailed formula
     * @param _forecast The forecast details
     * @param _market The market details
     * @return Points awarded
     */
    function calculatePoints(
        Forecast memory _forecast,
        Market memory _market
    ) public pure returns (uint256) {
        // Only calculate points for correct forecasts
        if (_forecast.side != _market.resolvedSide) {
            return 0;
        }
        
        // 1. Market Size Weight (0.5 - 2.0 multiplier based on total volume)
        uint256 marketSizeWeight = calculateMarketSizeWeight(_market.totalVolume);
        
        // 2. Early participation bonus (1.0 - 2.0 multiplier)
        uint256 earlyBonus = calculateEarlyBonus(
            _market.createdAt,
            _market.expirationTime,
            _forecast.timestamp
        );
        
        // 3. Correctness multiplier (against bandwagoning)
        uint256 correctnessMultiplier = calculateCorrectnessMultiplier(
            _market.yesLiquidity,
            _market.noLiquidity,
            _market.resolvedSide
        );
        
        // Calculate final points
        // Base points are the USDT amount (in dollars, not wei)
        uint256 basePoints = _forecast.amount / 1e6; // Convert from USDT wei (6 decimals) to whole USDT
        
        // Apply multipliers (with fixed point division)
        uint256 points = basePoints;
        points = (points * marketSizeWeight) / BASE_MULTIPLIER;
        points = (points * earlyBonus) / BASE_MULTIPLIER;
        points = (points * correctnessMultiplier) / BASE_MULTIPLIER;
        
        return points;
    }
    
    /**
     * @dev Calculate market size weight
     * @param _totalVolume Total volume of the market in USDT
     * @return Market size weight multiplier
     */
    function calculateMarketSizeWeight(uint256 _totalVolume) public pure returns (uint256) {
        // Base weight is 0.5, increases by 0.1 for each 100 USDT volume
        uint256 volumeInUSDT = _totalVolume / 1e6; // Convert from USDT wei to USDT
        uint256 weight = MIN_MARKET_SIZE_WEIGHT + (volumeInUSDT * 100000 / 100);
        
        // Cap at 2.0
        if (weight > MAX_MARKET_SIZE_WEIGHT) {
            weight = MAX_MARKET_SIZE_WEIGHT;
        }
        
        return weight;
    }
    
    /**
     * @dev Calculate early participation bonus
     * @param _createdAt Market creation timestamp
     * @param _expirationTime Market expiration timestamp
     * @param _forecastTime Forecast timestamp
     * @return Early participation bonus multiplier
     */
    function calculateEarlyBonus(
        uint256 _createdAt,
        uint256 _expirationTime,
        uint256 _forecastTime
    ) public pure returns (uint256) {
        uint256 marketDuration = _expirationTime - _createdAt;
        
        // Ensure no division by zero
        if (marketDuration == 0) {
            return MIN_EARLY_BONUS;
        }
        
        uint256 forecastDelay = _forecastTime - _createdAt;
        
        // Ensure no negative values
        if (forecastDelay > marketDuration) {
            forecastDelay = marketDuration;
        }
        
        // Calculate bonus: 1.0 + (1.0 * (marketDuration - forecastDelay) / marketDuration)
        uint256 earlyRatio = ((marketDuration - forecastDelay) * BASE_MULTIPLIER) / marketDuration;
        uint256 bonus = MIN_EARLY_BONUS + earlyRatio;
        
        // Cap at 2.0
        if (bonus > MAX_EARLY_BONUS) {
            bonus = MAX_EARLY_BONUS;
        }
        
        return bonus;
    }
    
    /**
     * @dev Calculate correctness multiplier (anti-bandwagon)
     * @param _yesLiquidity YES pool liquidity
     * @param _noLiquidity NO pool liquidity
     * @param _resolvedSide Resolved outcome
     * @return Correctness multiplier
     */
    function calculateCorrectnessMultiplier(
        uint256 _yesLiquidity,
        uint256 _noLiquidity,
        Side _resolvedSide
    ) public pure returns (uint256) {
        uint256 totalLiquidity = _yesLiquidity + _noLiquidity;
        
        // Ensure no division by zero
        if (totalLiquidity == 0) {
            return BASE_MULTIPLIER;
        }
        
        uint256 correctRatio;
        
        if (_resolvedSide == Side.Yes) {
            correctRatio = (_yesLiquidity * BASE_MULTIPLIER) / totalLiquidity;
        } else {
            correctRatio = (_noLiquidity * BASE_MULTIPLIER) / totalLiquidity;
        }
        
        // Calculate multiplier: 1.0 + (1.0 - correctRatio)
        // Rewards predicting against the crowd
        uint256 multiplier = BASE_MULTIPLIER + (BASE_MULTIPLIER - correctRatio);
        
        // Cap at 2.0
        if (multiplier > MAX_CORRECTNESS_MULTIPLIER) {
            multiplier = MAX_CORRECTNESS_MULTIPLIER;
        }
        
        return multiplier;
    }
    
    /**
     * @dev Batch calculate points for multiple forecasts
     * @param _forecasts Array of forecasts
     * @param _market The market details
     * @return Array of points awarded
     */
    function batchCalculatePoints(
        Forecast[] memory _forecasts,
        Market memory _market
    ) external pure returns (uint256[] memory) {
        uint256[] memory points = new uint256[](_forecasts.length);
        
        for (uint256 i = 0; i < _forecasts.length; i++) {
            points[i] = calculatePoints(_forecasts[i], _market);
        }
        
        return points;
    }
}