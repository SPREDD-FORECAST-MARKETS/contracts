// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SpreddMarket
 * @dev Individual binary prediction market contract - bet-based (no AMM)
 * Users can only place bets and add more to existing bets
 * Fee structure: 2% to creator, 10% to reward pool, 1% to factory, 87% to winning pool
 */
contract SpreddMarket is Ownable, ReentrancyGuard {
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
        uint256 totalVolumeA; // Total bets on option A
        uint256 totalVolumeB; // Total bets on option B
        uint256 creatorFee;   // Accumulated creator fees
        uint256 factoryFee;   // Accumulated factory fees
        bool resolved;
        bool feesDistributed; // Whether fees have been distributed
    }

    /// @notice User bet tracking
    struct UserBet {
        uint256 amountA; // Amount bet on option A
        uint256 amountB; // Amount bet on option B
        bool claimed;    // Whether user has claimed winnings
        uint256 firstPositionTime;
    }

    bytes32 public immutable marketId;
    address public factory;
    IERC20 public immutable token; // ERC-20 token used for betting
    uint256 public immutable marketCreationTime;
    
    MarketInfo public marketInfo;
    
    // User bets mapping
    mapping(address => UserBet) public userBets;
    
    // Track all users who have placed bets
    address[] public bettors;
    mapping(address => bool) public isBettor;
    
    // Trading statistics
    uint256 public totalBetCount;
    
    // Fee configuration
    uint256 public constant creatorFeePercent = 2; // 2%
    uint256 public constant rewardPoolPercent = 10; // 10%
    uint256 public constant factoryFeePercent = 1;  // 1%
    uint256 public constant totalFeePercent = 13; // 13% total fees

    address public immutable fpManager; // FP Manager contract
    uint256 public winningPoolSize;
    /// @notice Events
    event BetPlaced(
        address indexed user,
        bool betOnA,
        uint256 amount,
        uint256 totalUserBetA,
        uint256 totalUserBetB,
        uint256 totalVolumeA,
        uint256 totalVolumeB
    );

    event MarketResolved(MarketOutcome outcome);

    event FeesDistributed(
        uint256 creatorFee,
        uint256 rewardPoolFee,
        uint256 factoryFee
    );

    event WinningsClaimed(
        address indexed user,
        uint256 originalBet,
        uint256 winnings,
        uint256 totalPayout
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
            totalVolumeA: 0,
            totalVolumeB: 0,
            creatorFee: 0,
            factoryFee: 0,
            resolved: false,
            feesDistributed: false
        });
    }

    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @notice Track new bettor
     */
    function _trackBettor(address _user) internal {
        if (!isBettor[_user]) {
            bettors.push(_user);
            isBettor[_user] = true;
            userBets[_user].firstPositionTime = block.timestamp;
        }
    }

    /**
     * @notice Place a bet on Option A or Option B (can add to existing bets)
     */
    function placeBet(bool _betOnA, uint256 _amount) external nonReentrant {
        require(!marketInfo.resolved, "Market already resolved");
        require(block.timestamp < marketInfo.endTime, "Market has ended");
        require(_amount > 0, "Amount must be positive");

        // Track bettor
        _trackBettor(msg.sender);

        // Transfer tokens from user to contract
        token.safeTransferFrom(msg.sender, address(this), _amount);

        // Store the full bet amount (no fees deducted during betting)
        uint256 betAmount = _amount;

        // Update user bet and market totals
        UserBet storage userBet = userBets[msg.sender];
        
        if (_betOnA) {
            userBet.amountA += betAmount;
            marketInfo.totalVolumeA += betAmount;
        } else {
            userBet.amountB += betAmount;
            marketInfo.totalVolumeB += betAmount;
        }

        // Update statistics
        totalBetCount++;

        _awardCreatorFP();

        emit BetPlaced(
            msg.sender, 
            _betOnA, 
            betAmount, 
            userBet.amountA, 
            userBet.amountB,
            marketInfo.totalVolumeA,
            marketInfo.totalVolumeB
        );
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
                marketInfo.totalVolumeA + marketInfo.totalVolumeB,
                totalBetCount
            )
        );
        // Don't revert if FP award fails to avoid breaking core functionality
        if (!success) {
            // Could emit an event for monitoring
        }
    }

    /**
     * @notice Award FP to winning traders
     */
    function _awardTraderFP(address user, MarketOutcome _outcome) internal {
        UserBet memory position = userBets[user];
        
        // Get user's winning token amount
        uint256 winningTokens = _outcome == MarketOutcome.OPTION_A ? position.amountA : position.amountB;
        
        // Award FP only if user has winning tokens
        if (winningTokens > 0) {
            // Determine correct side liquidity for FP calculation
            uint256 correctSideLiquidity = _outcome == MarketOutcome.OPTION_A ? marketInfo.totalVolumeA : marketInfo.totalVolumeB;
            
            uint256 totalLiquidity = marketInfo.totalVolumeA + marketInfo.totalVolumeB;
            uint256 marketDuration = marketInfo.endTime - marketCreationTime;
            uint256 marketVolume = marketInfo.totalVolumeA + marketInfo.totalVolumeB;
            
            // Call FP Manager to award trader points
            (bool _success, ) = fpManager.call(
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

    /**
     * @notice Resolve market with winning option and distribute fees
     */
    function resolveMarket(MarketOutcome _outcome) external {
        require(msg.sender == owner(), "Only owner can resolve market");
        require(block.timestamp >= marketInfo.endTime, "Market hasn't ended yet");
        require(!marketInfo.resolved, "Market already resolved");
        require(_outcome != MarketOutcome.UNRESOLVED, "Invalid outcome");

        marketInfo.outcome = _outcome;
        marketInfo.resolved = true;
        marketInfo.feesDistributed = true;

        // Distribute fees immediately
        uint256 totalPool = marketInfo.totalVolumeA + marketInfo.totalVolumeB;
        uint256 creatorReward = (totalPool * creatorFeePercent) / 100;
        uint256 rewardPoolReward = (totalPool * rewardPoolPercent) / 100;
        uint256 factoryReward = (totalPool * factoryFeePercent) / 100;

        // Distribute fees
        if (creatorReward > 0) {
            token.safeTransfer(owner(), creatorReward);
        }
        if (rewardPoolReward > 0) {
          token.safeTransfer(fpManager, rewardPoolReward);
        }
        if (factoryReward > 0) {
            token.safeTransfer(factory, factoryReward);
        }

        winningPoolSize = token.balanceOf(address(this));

        emit MarketResolved(_outcome);
        emit FeesDistributed(creatorReward, rewardPoolReward, factoryReward);

    }

    /**
     * @notice Calculate user's winnings and total payout
     */
    function getUserWinnings(address _user) 
        external 
        view 
        returns (
            uint256 originalBet,
            uint256 winnings, 
            uint256 totalPayout,
            bool canClaim
        ) 
    {
        if (!marketInfo.resolved) {
            return (0, 0, 0, false);
        }

        UserBet memory userBet = userBets[_user];
        
        if (userBet.claimed || (userBet.amountA == 0 && userBet.amountB == 0)) {
            return (0, 0, 0, false);
        }

        // Handle special case: only one side has bets (refund scenario)
        if (marketInfo.totalVolumeA == 0 || marketInfo.totalVolumeB == 0) {
            originalBet = userBet.amountA + userBet.amountB;
            return (originalBet, 0, originalBet, true);
        }

        // Normal case: calculate winnings based on outcome
        uint256 userWinningBet;
        uint256 totalWinningVolume;
        uint256 totalPool = marketInfo.totalVolumeA + marketInfo.totalVolumeB;

        if (marketInfo.outcome == MarketOutcome.OPTION_A) {
            userWinningBet = userBet.amountA;
            totalWinningVolume = marketInfo.totalVolumeA;
            originalBet = userBet.amountA;
        } else if (marketInfo.outcome == MarketOutcome.OPTION_B) {
            userWinningBet = userBet.amountB;
            totalWinningVolume = marketInfo.totalVolumeB;
            originalBet = userBet.amountB;
        }

        if (userWinningBet > 0 && totalWinningVolume > 0) {
            // Winner gets their original bet PLUS proportional share of losing side after fees
            // Total pool available = total volume (fees deducted during resolution)

            require(winningPoolSize > 0, "Winning pool size not set");
            // uint256 totalPoolAfterFees = totalPool - (totalPool * totalFeePercent) / 100;   // changed this
            
            // Calculate user's proportional share of the total pool after fees
            uint256 userProportion = (userWinningBet * 1e18) / totalWinningVolume;
            totalPayout = (winningPoolSize * userProportion) / 1e18;
            winnings = totalPayout > originalBet ? totalPayout - originalBet : 0;
            
            return (originalBet, winnings, totalPayout, true);
        }

        return (0, 0, 0, false);
    }

    /**
     * @notice Claim winnings after market resolution
     */
    function claimWinnings() external nonReentrant {
        require(marketInfo.resolved, "Market not resolved yet");
        require(!userBets[msg.sender].claimed, "Already claimed");

        UserBet storage userBet = userBets[msg.sender];
        require(userBet.amountA > 0 || userBet.amountB > 0, "No bets found");

        // Get user's winnings
        (uint256 originalBet, uint256 winnings, uint256 totalPayout, bool canClaim) = this.getUserWinnings(msg.sender);
        require(canClaim, "No winnings to claim");

        userBet.claimed = true;

        // Award FP for winning trades (only for normal winning scenarios)
        if (winnings > 0) {
            _awardTraderFP(msg.sender, marketInfo.outcome);
        }

        // Transfer total payout to user
        if (totalPayout > 0) {
            token.safeTransfer(msg.sender, totalPayout);
        }

        emit WinningsClaimed(msg.sender, originalBet, winnings, totalPayout);
    }

    /**
     * @notice Calculate potential winnings for a bet amount
     */
    function calculatePotentialWinnings(bool _betOnA, uint256 _betAmount) 
        external 
        view 
        returns (uint256 potentialWinnings, uint256 netBetAmount) 
    {
        // Net bet amount is the full amount (no fees deducted during betting)
        netBetAmount = _betAmount;
        
        uint256 currentWinningVolume = _betOnA ? marketInfo.totalVolumeA : marketInfo.totalVolumeB;
        uint256 newWinningVolume = currentWinningVolume + netBetAmount;
        uint256 totalCurrentVolume = marketInfo.totalVolumeA + marketInfo.totalVolumeB;
        uint256 newTotalVolume = totalCurrentVolume + netBetAmount;
        
        if (newWinningVolume == 0) {
            potentialWinnings = 0;
        } else {
            // Calculate total pool after fees (fees only deducted once at resolution)
            uint256 totalPoolAfterFees = newTotalVolume - (newTotalVolume * totalFeePercent) / 100;
            uint256 userProportion = (netBetAmount * 1e18) / newWinningVolume;
            potentialWinnings = (totalPoolAfterFees * userProportion) / 1e18;
        }
    }

    /**
     * @notice Get current market odds (implied probability)
     */
    function getMarketOdds() 
        external 
        view 
        returns (uint256 oddsA, uint256 oddsB, uint256 totalVolume) 
    {
        totalVolume = marketInfo.totalVolumeA + marketInfo.totalVolumeB;
        
        if (totalVolume == 0) {
            oddsA = 500000; // 50% in basis points (1e6 = 100%)
            oddsB = 500000; // 50%
        } else {
            // Calculate implied probability (what % of total volume is on each side)
            oddsA = (marketInfo.totalVolumeA * 1e6) / totalVolume; 
            oddsB = (marketInfo.totalVolumeB * 1e6) / totalVolume;
        }
    }

    /**
     * @notice Calculate user's expected winnings if they win for each option
     */
    function getUserExpectedWinnings(address _user) 
        external 
        view 
        returns (uint256 expectedWinningsA, uint256 expectedWinningsB) 
    {
        if (!marketInfo.resolved) {
            UserBet memory userBet = userBets[_user];
            uint256 totalVolume = marketInfo.totalVolumeA + marketInfo.totalVolumeB;
            uint256 totalPoolAfterFees = totalVolume - (totalVolume * totalFeePercent) / 100;
            
            // Calculate expected winnings for Option A
            if (userBet.amountA > 0 && marketInfo.totalVolumeA > 0) {
                uint256 proportionA = (userBet.amountA * 1e18) / marketInfo.totalVolumeA;
                expectedWinningsA = (totalPoolAfterFees * proportionA) / 1e18;
            }
            
            // Calculate expected winnings for Option B
            if (userBet.amountB > 0 && marketInfo.totalVolumeB > 0) {
                uint256 proportionB = (userBet.amountB * 1e18) / marketInfo.totalVolumeB;
                expectedWinningsB = (totalPoolAfterFees * proportionB) / 1e18;
            }
        }
    }

    /**
     * @notice Send fees to factory and update accounting
     */

//     function sendFeesToFactory() internal {
//     uint256 feeAmount = calculateFees();
    
//     IERC20(token).safeTransfer(factory, feeAmount);
    
//     ISpreddFactory(factoryAddress).recordFeeFromMarket(feeAmount);
// }

    /**
     * @notice Get user's bet information
     */
    function getUserBet(address _user) 
        external 
        view 
        returns (uint256 amountA, uint256 amountB, bool claimed, uint256 firstPositionTime) 
    {
        UserBet memory bet = userBets[_user];
        return (bet.amountA, bet.amountB, bet.claimed, bet.firstPositionTime);
    }

    /**
     * @notice Get market volume breakdown
     */
    function getMarketVolumes() 
        external 
        view 
        returns (
            uint256 volumeA, 
            uint256 volumeB, 
            uint256 totalVolume, 
            uint256 creatorFees, 
            uint256 factoryFees,
            uint256 totalBets,
            bool feesDistributed
        ) 
    {
        return (
            marketInfo.totalVolumeA,
            marketInfo.totalVolumeB,
            marketInfo.totalVolumeA + marketInfo.totalVolumeB,
            marketInfo.creatorFee,
            marketInfo.factoryFee,
            totalBetCount,
            marketInfo.feesDistributed
        );
    }

    /**
     * @notice Get market info
     */
    function getMarketInfo() 
        external 
        view 
        returns (
            string memory question,
            string memory optionA,
            string memory optionB,
            uint256 endTime,
            MarketOutcome outcome,
            bool resolved,
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
            marketCreationTime
        );
    }

    /**
     * @notice Get total value locked in the market
     */
    function getTotalValue() external view returns (uint256) {
        return marketInfo.totalVolumeA + marketInfo.totalVolumeB;
    }

    /**
     * @notice Get the ERC-20 token address used by this market
     */
    function getTokenAddress() external view returns (address) {
        return address(token);
    }

    /**
     * @notice Get all bettors
     */
    function getAllBettors() external view returns (address[] memory) {
        return bettors;
    }

    /**
     * @notice Get number of unique bettors
     */
    function getBettorCount() external view returns (uint256) {
        return bettors.length;
    }

    /**
     * @notice Get winning pool size after fees
     */
    function getWinningPoolSize() external view returns (uint256) {
        if (!marketInfo.resolved) return 0;
        
        return winningPoolSize;
    }

    /**
     * @notice Withdraw accumulated fees (only owner, emergency function)
     */
    function emergencyWithdraw() external {
        require(msg.sender == owner(), "Only owner can emergency withdraw");
        require(marketInfo.resolved, "Market must be resolved first");
        
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.safeTransfer(owner(), balance);
        }
    }
}




