// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@thirdweb-dev/contracts/eip/interface/IERC20.sol";
import {ReentrancyGuard} from "@thirdweb-dev/contracts/external-deps/openzeppelin/security/ReentrancyGuard.sol";
import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";

/**
 * @title BinaryAMMPredictionMarket
 * @dev Individual binary prediction market contract with CPMM
 */
contract BinaryAMMPredictionMarket is Ownable, ReentrancyGuard {
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

    IERC20 public bettingToken;
    bytes32 public immutable marketId;
    address public factory;
    
    MarketInfo public marketInfo;
    
    // User balances (outcome tokens they can redeem if they win)
    mapping(address => uint256) public optionABalance;
    mapping(address => uint256) public optionBBalance;
    mapping(address => bool) public hasClaimed;
    
    // Liquidity provider tracking
    mapping(address => uint256) public lpTokens;
    
    // Fee configuration (in basis points, e.g., 30 = 0.3%)
    uint256 public tradingFee = 30; // 0.3% trading fee
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant PRECISION = 1e18;

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
        uint256 fee
    );

    event TokensSold(
        address indexed trader,
        bool sellingA,
        uint256 tokensIn,
        uint256 amountOut,
        uint256 newPriceA,
        uint256 fee
    );

    event MarketResolved(MarketOutcome outcome);

    event Claimed(
        address indexed user,
        uint256 amount
    );

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory can call this");
        _;
    }

    constructor(
        bytes32 _marketId,
        address _bettingToken,
        address _owner,
        string memory _question,
        string memory _optionA,
        string memory _optionB,
        uint256 _endTime
    ) {
        marketId = _marketId;
        bettingToken = IERC20(_bettingToken);
        factory = msg.sender;
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
     * @notice Initialize market with equal probability (0.5 each)
     * @param _initialLiquidity Initial liquidity amount (will be split equally)
     */
    function initializeMarket(uint256 _initialLiquidity) external nonReentrant {
        require(!marketInfo.initialized, "Market already initialized");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_initialLiquidity > 0, "Initial liquidity must be positive");

        // Transfer tokens from initializer
        require(
            bettingToken.transferFrom(msg.sender, address(this), _initialLiquidity),
            "Token transfer failed"
        );

        // Start with equal shares (0.5 probability each)
        uint256 initialShares = sqrt(_initialLiquidity * PRECISION);
        
        marketInfo.sharesA = initialShares;
        marketInfo.sharesB = initialShares;
        marketInfo.k = initialShares * initialShares;
        marketInfo.initialized = true;

        // Give LP tokens to initializer (using geometric mean)
        uint256 lpTokensAmount = initialShares;
        lpTokens[msg.sender] = lpTokensAmount;
        marketInfo.totalLpTokens = lpTokensAmount;

        emit LiquidityAdded(msg.sender, _initialLiquidity, lpTokensAmount);
    }

    /**
     * @notice Add liquidity to maintain current price ratio
     */
    function addLiquidity(uint256 _amount) external nonReentrant {
        require(marketInfo.initialized, "Market not initialized");
        require(!marketInfo.resolved, "Market already resolved");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_amount > 0, "Amount must be positive");

        // Transfer tokens
        require(
            bettingToken.transferFrom(msg.sender, address(this), _amount),
            "Token transfer failed"
        );

        // Calculate LP tokens to mint proportional to current pool
        uint256 lpTokensAmount = (_amount * marketInfo.totalLpTokens) / getTotalValue();

        // The new liquidity doesn't change the price, just adds depth
        uint256 scaleFactor = (getTotalValue() + _amount) * PRECISION / getTotalValue();
        marketInfo.sharesA = (marketInfo.sharesA * scaleFactor) / PRECISION;
        marketInfo.sharesB = (marketInfo.sharesB * scaleFactor) / PRECISION;
        marketInfo.k = marketInfo.sharesA * marketInfo.sharesB;

        // Mint LP tokens
        lpTokens[msg.sender] += lpTokensAmount;
        marketInfo.totalLpTokens += lpTokensAmount;

        emit LiquidityAdded(msg.sender, _amount, lpTokensAmount);
    }

    /**
     * @notice Remove liquidity proportionally
     */
    function removeLiquidity(uint256 _lpTokens) external nonReentrant {
        require(marketInfo.initialized, "Market not initialized");
        require(lpTokens[msg.sender] >= _lpTokens, "Insufficient LP tokens");
        require(_lpTokens > 0, "LP tokens must be positive");

        // Calculate proportional amount to withdraw
        uint256 totalValue = getTotalValue();
        uint256 amountOut = (_lpTokens * totalValue) / marketInfo.totalLpTokens;

        // Scale down shares proportionally
        uint256 scaleFactor = (totalValue - amountOut) * PRECISION / totalValue;
        marketInfo.sharesA = (marketInfo.sharesA * scaleFactor) / PRECISION;
        marketInfo.sharesB = (marketInfo.sharesB * scaleFactor) / PRECISION;
        marketInfo.k = marketInfo.sharesA * marketInfo.sharesB;

        // Burn LP tokens
        lpTokens[msg.sender] -= _lpTokens;
        marketInfo.totalLpTokens -= _lpTokens;

        // Transfer tokens back to user
        require(bettingToken.transfer(msg.sender, amountOut), "Token transfer failed");

        emit LiquidityRemoved(msg.sender, amountOut, _lpTokens);
    }

    /**
     * @notice Buy outcome tokens using betting tokens
     */
    function buyTokens(
        bool _buyOptionA,
        uint256 _amountIn,
        uint256 _minTokensOut
    ) external nonReentrant {
        require(marketInfo.initialized, "Market not initialized");
        require(!marketInfo.resolved, "Market already resolved");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_amountIn > 0, "Amount must be positive");

        // Transfer betting tokens from user
        require(
            bettingToken.transferFrom(msg.sender, address(this), _amountIn),
            "Token transfer failed"
        );

        // Calculate fee
        uint256 fee = (_amountIn * tradingFee) / FEE_DENOMINATOR;
        uint256 amountInAfterFee = _amountIn - fee;

        uint256 tokensOut;
        uint256 newPriceA;

        if (_buyOptionA) {
            // Buying Option A decreases sharesA, increases sharesB
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
            // Buying Option B decreases sharesB, increases sharesA
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

        emit TokensBought(msg.sender, _buyOptionA, _amountIn, tokensOut, newPriceA, fee);
    }

    /**
     * @notice Sell outcome tokens for betting tokens
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

        if (_sellOptionA) {
            require(optionABalance[msg.sender] >= _tokensIn, "Insufficient Option A tokens");
            
            // Selling Option A increases sharesA, decreases sharesB
            uint256 newSharesA = marketInfo.sharesA + _tokensIn;
            uint256 newSharesB = marketInfo.k / newSharesA;
            amountOut = marketInfo.sharesB - newSharesB;
            
            marketInfo.sharesA = newSharesA;
            marketInfo.sharesB = newSharesB;
            optionABalance[msg.sender] -= _tokensIn;
            
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        } else {
            require(optionBBalance[msg.sender] >= _tokensIn, "Insufficient Option B tokens");
            
            // Selling Option B increases sharesB, decreases sharesA
            uint256 newSharesB = marketInfo.sharesB + _tokensIn;
            uint256 newSharesA = marketInfo.k / newSharesB;
            amountOut = marketInfo.sharesA - newSharesA;
            
            marketInfo.sharesA = newSharesA;
            marketInfo.sharesB = newSharesB;
            optionBBalance[msg.sender] -= _tokensIn;
            
            newPriceA = (newSharesB * PRECISION) / (newSharesA + newSharesB);
        }

        // Apply fee
        uint256 fee = (amountOut * tradingFee) / FEE_DENOMINATOR;
        uint256 amountOutAfterFee = amountOut - fee;
        
        require(amountOutAfterFee >= _minAmountOut, "Slippage too high");

        // Transfer betting tokens to user
        require(bettingToken.transfer(msg.sender, amountOutAfterFee), "Token transfer failed");

        emit TokensSold(msg.sender, _sellOptionA, _tokensIn, amountOutAfterFee, newPriceA, fee);
    }

    /**
     * @notice Get current price of Option A
     */
    function getPriceA() external view returns (uint256) {
        if (!marketInfo.initialized) return PRECISION / 2; // 0.5 default
        return (marketInfo.sharesB * PRECISION) / (marketInfo.sharesA + marketInfo.sharesB);
    }

    /**
     * @notice Get current price of Option B
     */
    function getPriceB() external view returns (uint256) {
        uint256 priceA = this.getPriceA();
        return PRECISION - priceA;
    }

    /**
     * @notice Get both prices at once
     */
    function getCurrentPrices() external view returns (uint256 priceA, uint256 priceB) {
        priceA = this.getPriceA();
        priceB = PRECISION - priceA;
    }

    /**
     * @notice Calculate buy outcome
     */
    function calculateBuyTokensOut(
        bool _buyOptionA,
        uint256 _amountIn
    ) external view returns (uint256 tokensOut, uint256 fee, uint256 newPriceA) {
        require(marketInfo.initialized, "Market not initialized");
        
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
    }

    /**
     * @notice Calculate sell outcome
     */
    function calculateSellTokensOut(
        bool _sellOptionA,
        uint256 _tokensIn
    ) external view returns (uint256 amountOut, uint256 fee, uint256 newPriceA) {
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
     * @notice Get total value locked in the market
     */
    function getTotalValue() public view returns (uint256) {
        if (!marketInfo.initialized) return 0;
        return marketInfo.sharesA + marketInfo.sharesB;
    }

    /**
     * @notice Resolve market with outcome (only owner)
     */
    function resolveMarket(MarketOutcome _outcome) external {
        require(msg.sender == owner(), "Only owner can resolve market");
        require(block.timestamp >= marketInfo.endTime, "Market hasn't ended yet");
        require(!marketInfo.resolved, "Market already resolved");
        require(_outcome != MarketOutcome.UNRESOLVED, "Invalid outcome");

        marketInfo.outcome = _outcome;
        marketInfo.resolved = true;

        emit MarketResolved(_outcome);
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

        // Winner gets 1:1 payout in betting tokens
        require(bettingToken.transfer(msg.sender, winningTokens), "Token transfer failed");

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
     * @notice Get market AMM state
     */
    function getMarketState() 
        external 
        view 
        returns (uint256 sharesA, uint256 sharesB, uint256 k, uint256 priceA, uint256 priceB, bool initialized, uint256 endTime) 
    {
        uint256 currentPriceA = this.getPriceA();
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
        uint256 balance = bettingToken.balanceOf(address(this));
        uint256 totalLocked = getTotalValue();
        
        require(balance > totalLocked, "No fees to withdraw");
        uint256 fees = balance - totalLocked;
        
        require(bettingToken.transfer(owner(), fees), "Token transfer failed");
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