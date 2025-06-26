// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {ReentrancyGuard} from "@thirdweb-dev/contracts/external-deps/openzeppelin/security/ReentrancyGuard.sol";
import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BinaryAMMPredictionMarket
 * @dev Individual binary prediction market contract with CPMM using ERC-20 tokens
 * Implements Constant Product Market Maker (x * y = k) for automated market making
 * Integrated with WeeklyForecastPointManager for FP tracking
 */
contract BinaryAMMPredictionMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Market prediction outcome enum
    enum MarketOutcome {
        UNRESOLVED,
        OPTION_A,
        OPTION_B
    }

    /// @notice Market information struct
    struct MarketInfo {
        string question;
        uint256 endTime;
        MarketOutcome outcome;
        string optionA;
        string optionB;
        // AMM shares (these represent the market's belief about probabilities)
        uint256 sharesA; // Shares for Option A
        uint256 sharesB; // Shares for Option B
        uint256 k; // Constant product (sharesA * sharesB)
        bool resolved;
        bool initialized;
        uint256 totalLpTokens;
    }

    /// @notice User position tracking for FP calculation
    struct UserPosition {
        uint256 firstPositionTime;    // When user first bought tokens in this market
        bool hasPosition;             // Whether user has any position
    }

    bytes32 public immutable marketId;
    address public factory;
    IERC20 public immutable token; // ERC-20 token used for trading
    uint256 public immutable marketCreationTime; // When market was created
    address public immutable fpManager; // FP Manager contract
    
    MarketInfo public marketInfo;
    
    // User balances (outcome tokens they can redeem if they win)
    mapping(address => uint256) public optionABalance;
    mapping(address => uint256) public optionBBalance;
    mapping(address => bool) public hasClaimed;
    
    // FP tracking - user positions and timing
    mapping(address => UserPosition) public userPositions;
    address[] public usersWithPositions; // Array of all users who have positions
    mapping(address => bool) public isUserTracked; // To avoid duplicate entries
    uint256 public totalTradeCount; // Total number of trades in this market
    
    // Liquidity provider tracking
    mapping(address => uint256) public lpTokens;
    
    // Fee configuration (in basis points, e.g., 30 = 0.3%)
    uint256 public tradingFee = 30; // 0.3% trading fee
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant PRECISION = 1e6;
    
    // CPMM parameters
    uint256 public constant MIN_LIQUIDITY = 1000; // Minimum liquidity to prevent division by zero
    uint256 public constant MAX_PRICE_IMPACT = 9000; // 90% max price impact in basis points

    /// @notice Events
    event LiquidityAdded(
        address indexed provider,
        uint256 amount,
        uint256 lpTokens
    );

    event LiquidityRemoved(
        address indexed provider,
        uint256 amount,
        uint256 lpTokens
    );

    event TokensBought(
        address indexed trader,
        bool buyingA,
        uint256 amountIn,
        uint256 tokensOut,
        uint256 newPriceA,
        uint256 fee,
        uint256 priceImpact
    );

    event TokensSold(
        address indexed trader,
        bool sellingA,
        uint256 tokensIn,
        uint256 amountOut,
        uint256 newPriceA,
        uint256 fee,
        uint256 priceImpact
    );

    event MarketResolved(MarketOutcome outcome);

    event Claimed(
        address indexed user,
        uint256 amount
    );

    event CPMMRebalanced(
        uint256 newSharesA,
        uint256 newSharesB,
        uint256 newK
    );

    event UserPositionTracked(
        address indexed user,
        uint256 firstPositionTime
    );

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory can call this");
        _;
    }

    constructor(
        bytes32 _marketId,
        address _owner,
        address _token,
        string memory _question,
        string memory _optionA,
        string memory _optionB,
        uint256 _endTime,
        address _fpManager
    ) {
        require(_fpManager != address(0), "Invalid FP Manager address");
        
        marketId = _marketId;
        factory = msg.sender;
        token = IERC20(_token);
        marketCreationTime = block.timestamp;
        fpManager = _fpManager;
        _setupOwner(_owner);
        
        marketInfo = MarketInfo({
            question: _question,
            optionA: _optionA,
            optionB: _optionB,
            endTime: _endTime,
            outcome: MarketOutcome.UNRESOLVED,
            sharesA: 0,
            sharesB: 0,
            k: 0,
            resolved: false,
            initialized: false,
            totalLpTokens: 0
        });
    }

    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @notice Track user position for FP calculation
     */
    function _trackUserPosition(address _user) internal {
        if (!userPositions[_user].hasPosition) {
            userPositions[_user] = UserPosition({
                firstPositionTime: block.timestamp,
                hasPosition: true
            });
            
            // Add to users array if not already tracked
            if (!isUserTracked[_user]) {
                usersWithPositions.push(_user);
                isUserTracked[_user] = true;
            }
            
            emit UserPositionTracked(_user, block.timestamp);
        }
    }

    /**
     * @notice Award creator FP for trading activity
     */
    function _awardCreatorFP() internal {
        // Call FP Manager to award creator points
        (bool success, ) = fpManager.call(
            abi.encodeWithSignature(
                "awardCreatorFP(address,bytes32,uint256,uint256)",
                owner(),
                marketId,
                getTotalValue(),
                totalTradeCount
            )
        );
        // Don't revert if FP award fails to avoid breaking core functionality
        if (!success) {
            // Could emit an event for monitoring
        }
    }

    /**
     * @notice Initialize market with equal probability (0.5 each) - CPMM setup
     */
    function initializeMarket(uint256 _amount) external nonReentrant {
        require(!marketInfo.initialized, "Market already initialized");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_amount >= MIN_LIQUIDITY, "Initial liquidity too low");

        // Transfer tokens from user to contract
        token.safeTransferFrom(msg.sender, address(this), _amount);

        // Start with equal shares (0.5 probability each) for CPMM
        // Using square root to ensure equal initial pricing
        uint256 initialShares = sqrt(_amount * PRECISION);
        
        marketInfo.sharesA = initialShares;
        marketInfo.sharesB = initialShares;
        marketInfo.k = initialShares * initialShares; // CPMM constant product
        marketInfo.initialized = true;

        // Give LP tokens to initializer (using geometric mean for fair distribution)
        uint256 lpTokensAmount = initialShares;
        lpTokens[msg.sender] = lpTokensAmount;
        marketInfo.totalLpTokens = lpTokensAmount;

        emit LiquidityAdded(msg.sender, _amount, lpTokensAmount);
        emit CPMMRebalanced(initialShares, initialShares, marketInfo.k);
    }

    /**
     * @notice Add liquidity to maintain current price ratio (CPMM liquidity provision)
     */
    function addLiquidity(uint256 _amount) external nonReentrant {
        require(marketInfo.initialized, "Market not initialized");
        require(!marketInfo.resolved, "Market already resolved");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_amount > 0, "Amount must be positive");

        // Transfer tokens from user to contract
        token.safeTransferFrom(msg.sender, address(this), _amount);

        // Calculate LP tokens to mint proportional to current pool
        uint256 totalValue = getTotalValue();
        uint256 lpTokensAmount = (_amount * marketInfo.totalLpTokens) / totalValue;

        // Scale both shares proportionally to maintain price (CPMM invariant)
        uint256 scaleFactor = (totalValue + _amount) * PRECISION / totalValue;
        marketInfo.sharesA = (marketInfo.sharesA * scaleFactor) / PRECISION;
        marketInfo.sharesB = (marketInfo.sharesB * scaleFactor) / PRECISION;
        marketInfo.k = marketInfo.sharesA * marketInfo.sharesB; // Update CPMM constant

        // Mint LP tokens
        lpTokens[msg.sender] += lpTokensAmount;
        marketInfo.totalLpTokens += lpTokensAmount;

        emit LiquidityAdded(msg.sender, _amount, lpTokensAmount);
        emit CPMMRebalanced(marketInfo.sharesA, marketInfo.sharesB, marketInfo.k);
    }

    /**
     * @notice Remove liquidity proportionally (CPMM liquidity removal)
     */
    function removeLiquidity(uint256 _lpTokens) external nonReentrant {
        require(marketInfo.initialized, "Market not initialized");
        require(lpTokens[msg.sender] >= _lpTokens, "Insufficient LP tokens");
        require(_lpTokens > 0, "LP tokens must be positive");

        // Calculate proportional amount to withdraw
        uint256 totalValue = getTotalValue();
        uint256 amountOut = (_lpTokens * totalValue) / marketInfo.totalLpTokens;
        
        // Ensure minimum liquidity remains
        require(totalValue - amountOut >= MIN_LIQUIDITY, "Would leave insufficient liquidity");

        // Scale down shares proportionally (maintain CPMM ratio)
        uint256 scaleFactor = (totalValue - amountOut) * PRECISION / totalValue;
        marketInfo.sharesA = (marketInfo.sharesA * scaleFactor) / PRECISION;
        marketInfo.sharesB = (marketInfo.sharesB * scaleFactor) / PRECISION;
        marketInfo.k = marketInfo.sharesA * marketInfo.sharesB; // Update CPMM constant

        // Burn LP tokens
        lpTokens[msg.sender] -= _lpTokens;
        marketInfo.totalLpTokens -= _lpTokens;

        // Transfer ERC-20 tokens back to user
        token.safeTransfer(msg.sender, amountOut);

        emit LiquidityRemoved(msg.sender, amountOut, _lpTokens);
        emit CPMMRebalanced(marketInfo.sharesA, marketInfo.sharesB, marketInfo.k);
    }

    /**
     * @notice Buy outcome tokens using ERC-20 tokens (CPMM buy mechanism)
     */
    function buyTokens(
        bool _buyOptionA,
        uint256 _amount,
        uint256 _minTokensOut
    ) external nonReentrant {
        require(marketInfo.initialized, "Market not initialized");
        require(!marketInfo.resolved, "Market already resolved");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_amount > 0, "Amount must be positive");

        // Track user position for FP calculation
        _trackUserPosition(msg.sender);

        // Transfer tokens from user to contract
        token.safeTransferFrom(msg.sender, address(this), _amount);

        // Calculate fee
        uint256 fee = (_amount * tradingFee) / FEE_DENOMINATOR;
        uint256 amountInAfterFee = _amount - fee;

        uint256 tokensOut;
        uint256 newPriceA;
        uint256 priceImpact;
        uint256 oldPriceA = getPriceA();

        if (_buyOptionA) {
            // CPMM: Buying Option A decreases sharesA, increases sharesB
            uint256 newSharesB = marketInfo.sharesB + amountInAfterFee;
            uint256 newSharesA = marketInfo.k / newSharesB;
            tokensOut = marketInfo.sharesA - newSharesA;
            
            require(tokensOut >= _minTokensOut, "Slippage too high");
            require(newSharesA > 0, "Insufficient liquidity");

            marketInfo.sharesA = newSharesA;
            marketInfo.sharesB = newSharesB;
            optionABalance[msg.sender] += tokensOut;
            
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        } else {
            // CPMM: Buying Option B decreases sharesB, increases sharesA
            uint256 newSharesA = marketInfo.sharesA + amountInAfterFee;
            uint256 newSharesB = marketInfo.k / newSharesA;
            tokensOut = marketInfo.sharesB - newSharesB;
            
            require(tokensOut >= _minTokensOut, "Slippage too high");
            require(newSharesB > 0, "Insufficient liquidity");

            marketInfo.sharesA = newSharesA;
            marketInfo.sharesB = newSharesB;
            optionBBalance[msg.sender] += tokensOut;
            
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        }

        // Calculate price impact
        priceImpact = oldPriceA > newPriceA ? 
            ((oldPriceA - newPriceA) * FEE_DENOMINATOR) / oldPriceA :
            ((newPriceA - oldPriceA) * FEE_DENOMINATOR) / oldPriceA;
        
        require(priceImpact <= MAX_PRICE_IMPACT, "Price impact too high");

        // Increment trade count and award creator FP
        totalTradeCount++;
        _awardCreatorFP();

        emit TokensBought(msg.sender, _buyOptionA, _amount, tokensOut, newPriceA, fee, priceImpact);
    }

    /**
     * @notice Sell outcome tokens for ERC-20 tokens (Enhanced CPMM sell mechanism)
     */
    function sellTokens(
        bool _sellOptionA,
        uint256 _tokensIn,
        uint256 _minAmountOut
    ) external nonReentrant {
        require(marketInfo.initialized, "Market not initialized");
        require(!marketInfo.resolved, "Market already resolved");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_tokensIn > 0, "Amount must be positive");

        uint256 amountOut;
        uint256 newPriceA;
        uint256 priceImpact;
        uint256 oldPriceA = getPriceA();

        if (_sellOptionA) {
            require(optionABalance[msg.sender] >= _tokensIn, "Insufficient Option A tokens");
            
            // CPMM: Selling Option A increases sharesA, decreases sharesB
            uint256 newSharesA = marketInfo.sharesA + _tokensIn;
            uint256 newSharesB = marketInfo.k / newSharesA;
            amountOut = marketInfo.sharesB - newSharesB;
            
            require(newSharesB > 0, "Insufficient liquidity");
            
            marketInfo.sharesA = newSharesA;
            marketInfo.sharesB = newSharesB;
            optionABalance[msg.sender] -= _tokensIn;
            
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        } else {
            require(optionBBalance[msg.sender] >= _tokensIn, "Insufficient Option B tokens");
            
            // CPMM: Selling Option B increases sharesB, decreases sharesA
            uint256 newSharesB = marketInfo.sharesB + _tokensIn;
            uint256 newSharesA = marketInfo.k / newSharesB;
            amountOut = marketInfo.sharesA - newSharesA;
            
            require(newSharesA > 0, "Insufficient liquidity");
            
            marketInfo.sharesA = newSharesA;
            marketInfo.sharesB = newSharesB;
            optionBBalance[msg.sender] -= _tokensIn;
            
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        }

        // Apply trading fee
        uint256 fee = (amountOut * tradingFee) / FEE_DENOMINATOR;
        uint256 amountOutAfterFee = amountOut - fee;
        
        require(amountOutAfterFee >= _minAmountOut, "Slippage too high");

        // Calculate price impact
        priceImpact = oldPriceA > newPriceA ? 
            ((oldPriceA - newPriceA) * FEE_DENOMINATOR) / oldPriceA :
            ((newPriceA - oldPriceA) * FEE_DENOMINATOR) / oldPriceA;

        // Increment trade count and award creator FP
        totalTradeCount++;
        _awardCreatorFP();

        // Transfer ERC-20 tokens to user
        token.safeTransfer(msg.sender, amountOutAfterFee);

        emit TokensSold(msg.sender, _sellOptionA, _tokensIn, amountOutAfterFee, newPriceA, fee, priceImpact);
    }

    /**
     * @notice Market making function - automatically provide liquidity at current prices
     */
    function marketMake(uint256 _amount) external nonReentrant {
        require(marketInfo.initialized, "Market not initialized");
        require(!marketInfo.resolved, "Market already resolved");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_amount > 0, "Amount must be positive");

        // Transfer tokens from user to contract
        token.safeTransferFrom(msg.sender, address(this), _amount);

        // Split the incoming tokens to maintain current price ratio
        uint256 currentPriceA = getPriceA();
        uint256 priceB = PRECISION - currentPriceA;
        
        // Allocate proportionally to current prices
        uint256 amountForA = (_amount * priceB) / PRECISION;
        uint256 amountForB = _amount - amountForA;
        
        // Add to both sides to maintain price
        marketInfo.sharesA += amountForA;
        marketInfo.sharesB += amountForB;
        marketInfo.k = marketInfo.sharesA * marketInfo.sharesB;
        
        // Give LP tokens proportional to contribution
        uint256 lpTokensAmount = (_amount * marketInfo.totalLpTokens) / getTotalValue();
        lpTokens[msg.sender] += lpTokensAmount;
        marketInfo.totalLpTokens += lpTokensAmount;
        
        emit LiquidityAdded(msg.sender, _amount, lpTokensAmount);
        emit CPMMRebalanced(marketInfo.sharesA, marketInfo.sharesB, marketInfo.k);
    }

    /**
     * @notice Resolve market with outcome and award FP to winners
     */
    function resolveMarket(MarketOutcome _outcome) external {
        require(msg.sender == owner(), "Only owner can resolve market");
        require(block.timestamp >= marketInfo.endTime, "Market hasn't ended yet");
        require(!marketInfo.resolved, "Market already resolved");
        require(_outcome != MarketOutcome.UNRESOLVED, "Invalid outcome");

        marketInfo.outcome = _outcome;
        marketInfo.resolved = true;

        // Award FP to all winning traders
        _awardTraderFP(_outcome);

        emit MarketResolved(_outcome);
    }

    /**
     * @notice Award FP to winning traders
     */
    function _awardTraderFP(MarketOutcome _outcome) internal {
        // Determine correct side liquidity for FP calculation
        uint256 correctSideLiquidity = _outcome == MarketOutcome.OPTION_A ? 
            marketInfo.sharesA : marketInfo.sharesB;
        
        uint256 totalLiquidity = marketInfo.sharesA + marketInfo.sharesB;
        uint256 marketDuration = marketInfo.endTime - marketCreationTime;
        uint256 marketVolume = getTotalValue();
        
        // Iterate through all users with positions
        for (uint256 i = 0; i < usersWithPositions.length; i++) {
            address user = usersWithPositions[i];
            UserPosition memory position = userPositions[user];
            
            // Get user's winning token amount
            uint256 winningTokens = _outcome == MarketOutcome.OPTION_A ? 
                optionABalance[user] : optionBBalance[user];
                
            // Award FP only if user has winning tokens
            if (winningTokens > 0) {
                // Call FP Manager to award trader points
                (bool success, ) = fpManager.call(
                    abi.encodeWithSignature(
                        "awardTraderFP(address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256)",
                        user,                           // trader address
                        marketId,                       // market ID
                        marketVolume,                   // total market volume
                        position.firstPositionTime,     // when user first bought tokens
                        marketCreationTime,             // when market was created
                        marketDuration,                 // market duration
                        correctSideLiquidity,          // correct side liquidity
                        totalLiquidity,                // total liquidity
                        winningTokens                  // user's winning position size
                    )
                );
                // Don't revert if FP award fails to avoid breaking core functionality
            }
        }
    }

    /**
     * @notice Get current price of Option A (CPMM price calculation)
     */
    function getPriceA() public view returns (uint256) {
        if (!marketInfo.initialized) return PRECISION / 2; // 0.5 default
        return (marketInfo.sharesB * PRECISION) / (marketInfo.sharesA + marketInfo.sharesB);
    }

    /**
     * @notice Get current price of Option B
     */
    function getPriceB() external view returns (uint256) {
        return PRECISION - getPriceA();
    }

    /**
     * @notice Get both prices at once
     */
    function getCurrentPrices() external view returns (uint256 priceA, uint256 priceB) {
        priceA = getPriceA();
        priceB = PRECISION - priceA;
    }

    /**
     * @notice Calculate buy outcome with price impact
     */
    function calculateBuyTokensOut(
        bool _buyOptionA,
        uint256 _amountIn
    ) external view returns (uint256 tokensOut, uint256 fee, uint256 newPriceA, uint256 priceImpact) {
        require(marketInfo.initialized, "Market not initialized");
        
        uint256 oldPriceA = getPriceA();
        fee = (_amountIn * tradingFee) / FEE_DENOMINATOR;
        uint256 amountInAfterFee = _amountIn - fee;
        
        if (_buyOptionA) {
            uint256 newSharesB = marketInfo.sharesB + amountInAfterFee;
            uint256 newSharesA = marketInfo.k / newSharesB;
            tokensOut = marketInfo.sharesA - newSharesA;
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        } else {
            uint256 newSharesA = marketInfo.sharesA + amountInAfterFee;
            uint256 newSharesB = marketInfo.k / newSharesA;
            tokensOut = marketInfo.sharesB - newSharesB;
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        }
        
        priceImpact = oldPriceA > newPriceA ? 
            ((oldPriceA - newPriceA) * FEE_DENOMINATOR) / oldPriceA :
            ((newPriceA - oldPriceA) * FEE_DENOMINATOR) / oldPriceA;
    }

    /**
     * @notice Calculate sell outcome with price impact
     */
    function calculateSellTokensOut(
        bool _sellOptionA,
        uint256 _tokensIn
    ) public view returns (uint256 amountOut, uint256 fee, uint256 newPriceA) {
        require(marketInfo.initialized, "Market not initialized");
        
        if (_sellOptionA) {
            uint256 newSharesA = marketInfo.sharesA + _tokensIn;
            uint256 newSharesB = marketInfo.k / newSharesA;
            amountOut = marketInfo.sharesB - newSharesB;
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        } else {
            uint256 newSharesB = marketInfo.sharesB + _tokensIn;
            uint256 newSharesA = marketInfo.k / newSharesB;
            amountOut = marketInfo.sharesA - newSharesA;
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        }
        
        fee = (amountOut * tradingFee) / FEE_DENOMINATOR;
        amountOut = amountOut - fee;
    }

    /**
     * @notice Get CPMM invariant and current state
     */
    function getCPMMState() external view returns (
        uint256 sharesA,
        uint256 sharesB,
        uint256 k,
        uint256 priceA,
        uint256 priceB,
        uint256 totalValue,
        uint256 utilization
    ) {
        sharesA = marketInfo.sharesA;
        sharesB = marketInfo.sharesB;
        k = marketInfo.k;
        priceA = getPriceA();
        priceB = PRECISION - priceA;
        totalValue = getTotalValue();
        
        // Calculate utilization (how much of the liquidity is being used)
        if (totalValue > 0) {
            uint256 balancedValue = 2 * sqrt(marketInfo.k);
            utilization = totalValue > balancedValue ? 
                ((totalValue - balancedValue) * PRECISION) / totalValue : 0;
        }
    }

    /**
     * @notice Get total value locked in the market (in ERC-20 tokens)
     */
    function getTotalValue() public view returns (uint256) {
        if (!marketInfo.initialized) return 0;
        return marketInfo.sharesA + marketInfo.sharesB;
    }

    /**
     * @notice Claim winnings after market resolution
     */
    function claimWinnings() external nonReentrant {
        require(marketInfo.resolved, "Market not resolved yet");
        require(!hasClaimed[msg.sender], "Already claimed");

        uint256 winningTokens;
        if (marketInfo.outcome == MarketOutcome.OPTION_A) {
            winningTokens = optionABalance[msg.sender];
            optionABalance[msg.sender] = 0;
        } else if (marketInfo.outcome == MarketOutcome.OPTION_B) {
            winningTokens = optionBBalance[msg.sender];
            optionBBalance[msg.sender] = 0;
        } else {
            revert("Invalid market outcome");
        }

        require(winningTokens > 0, "No winnings to claim");
        hasClaimed[msg.sender] = true;

        // Winner gets 1:1 payout in ERC-20 tokens
        token.safeTransfer(msg.sender, winningTokens);

        emit Claimed(msg.sender, winningTokens);
    }

    /**
     * @notice Get user's token balances and LP tokens
     */
    function getUserBalances(address _user) 
        external 
        view 
        returns (uint256 optionA, uint256 optionB, uint256 lpTokensAmount) 
    {
        return (
            optionABalance[_user],
            optionBBalance[_user],
            lpTokens[_user]
        );
    }

    /**
     * @notice Get user's position info for FP tracking
     */
    function getUserPosition(address _user) 
        external 
        view 
        returns (uint256 firstPositionTime, bool hasPosition, uint256 optionA, uint256 optionB) 
    {
        UserPosition memory position = userPositions[_user];
        return (
            position.firstPositionTime,
            position.hasPosition,
            optionABalance[_user],
            optionBBalance[_user]
        );
    }

    /**
     * @notice Get market AMM state
     */
    function getMarketState() 
        external 
        view 
        returns (uint256 sharesA, uint256 sharesB, uint256 k, uint256 priceA, uint256 priceB, bool initialized, uint256 endTime) 
    {
        uint256 currentPriceA = getPriceA();
        return (
            marketInfo.sharesA, 
            marketInfo.sharesB, 
            marketInfo.k, 
            currentPriceA,
            PRECISION - currentPriceA,
            marketInfo.initialized,
            marketInfo.endTime
        );
    }

    /**
     * @notice Get market info including FP tracking data
     */
    function getMarketInfoWithFP() 
        external 
        view 
        returns (
            string memory question,
            string memory optionA,
            string memory optionB,
            uint256 endTime,
            MarketOutcome outcome,
            bool resolved,
            bool initialized,
            uint256 totalTrades,
            uint256 usersCount,
            uint256 creationTime
        ) 
    {
        return (
            marketInfo.question,
            marketInfo.optionA,
            marketInfo.optionB,
            marketInfo.endTime,
            marketInfo.outcome,
            marketInfo.resolved,
            marketInfo.initialized,
            totalTradeCount,
            usersWithPositions.length,
            marketCreationTime
        );
    }

    /**
     * @notice Get all users with positions (for FP calculation)
     */
    function getUsersWithPositions() external view returns (address[] memory) {
        return usersWithPositions;
    }

    /**
     * @notice Set trading fee (only owner)
     */
    function setTradingFee(uint256 _newFee) external {
        require(msg.sender == owner(), "Only owner can set fee");
        require(_newFee <= 500, "Fee too high"); // Max 5%
        tradingFee = _newFee;
    }

    /**
     * @notice Withdraw accumulated fees (only owner)
     */
    function withdrawFees() external {
        require(msg.sender == owner(), "Only owner can withdraw fees");
        uint256 balance = token.balanceOf(address(this));
        uint256 totalLocked = getTotalValue();
        
        require(balance > totalLocked, "No fees to withdraw");
        uint256 fees = balance - totalLocked;
        
        token.safeTransfer(owner(), fees);
    }

    /**
     * @notice Get the ERC-20 token address used by this market
     */
    function getTokenAddress() external view returns (address) {
        return address(token);
    }

    /**
     * @notice Get FP Manager address
     */
    function getFPManagerAddress() external view returns (address) {
        return fpManager;
    }

    /**
     * @notice Square root function for calculations
     */
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}