// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@thirdweb-dev/contracts/extension/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SpreddMarket
 * @dev Individual binary prediction market contract - bet-based (no AMM)
 * Users can only place bets and add more to existing bets
 * 10% to creator, 5% to factory, 85% to winning pool
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
    uint256 public constant creatorFeePercent = 10; // 10%
    uint256 public constant factoryFeePercent = 5;  // 5%

    address public immutable fpManager; // FP Manager contract


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

    event WinningsClaimed(
        address indexed user,
        uint256 amount
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
            resolved: false
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

        // Calculate fees: 10% creator + 5% factory = 15% total fees
        uint256 totalFees = (_amount * 15) / 100;
        uint256 betAmount = _amount - totalFees;
        
        uint256 creatorFee = (_amount * creatorFeePercent) / 100;
        uint256 factoryFee = (_amount * factoryFeePercent) / 100;

        // Update market fees
        marketInfo.creatorFee += creatorFee;
        marketInfo.factoryFee += factoryFee;

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
    function _awardTraderFP(MarketOutcome _outcome) internal {
        // Determine correct side liquidity for FP calculation
        uint256 correctSideLiquidity = _outcome == MarketOutcome.OPTION_A ? marketInfo.totalVolumeA : marketInfo.totalVolumeB;
        
        uint256 totalLiquidity = marketInfo.totalVolumeA + marketInfo.totalVolumeB;
        uint256 marketDuration = marketInfo.endTime - marketCreationTime;
        uint256 marketVolume = marketInfo.totalVolumeA + marketInfo.totalVolumeB;
        
        // Iterate through all users with positions
        for (uint256 i = 0; i < bettors.length; i++) {
            address user = bettors[i];
            UserBet memory position = userBets[user];
            
            // Get user's winning token amount
            uint256 winningTokens = _outcome == MarketOutcome.OPTION_A ? position.amountA : position.amountB;
                
            // Award FP only if user has winning tokens
            if (winningTokens > 0) {
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
    }

    /**
     * @notice Resolve market with winning option
     */
    function resolveMarket(MarketOutcome _outcome) external {
        require(msg.sender == owner(), "Only owner can resolve market");
        require(block.timestamp >= marketInfo.endTime, "Market hasn't ended yet");
        require(!marketInfo.resolved, "Market already resolved");
        require(_outcome != MarketOutcome.UNRESOLVED, "Invalid outcome");

        // Check if there are bets on both sides
        if (marketInfo.totalVolumeA == 0 || marketInfo.totalVolumeB == 0) {
            // If only one side has bets, set outcome but handle as special case in claiming
            marketInfo.outcome = _outcome;
            marketInfo.resolved = true;
            emit MarketResolved(_outcome);
            return;
        }

        marketInfo.outcome = _outcome;
        marketInfo.resolved = true;

        // Pay fees to creator and factory
        if (marketInfo.creatorFee > 0) {
            token.safeTransfer(owner(), marketInfo.creatorFee);
        }
        if (marketInfo.factoryFee > 0) {
            token.safeTransfer(factory, marketInfo.factoryFee);
        }

        _awardTraderFP(_outcome);

        emit MarketResolved(_outcome);
    }

    /**
     * @notice Claim winnings after market resolution
     */
    function claimWinnings() external nonReentrant {
        require(marketInfo.resolved, "Market not resolved yet");
        require(!userBets[msg.sender].claimed, "Already claimed");

        UserBet storage userBet = userBets[msg.sender];
        require(userBet.amountA > 0 || userBet.amountB > 0, "No bets found");

        userBet.claimed = true;

        uint256 payout = 0;

        // Handle special case: only one side has bets (refund scenario)
        if (marketInfo.totalVolumeA == 0 || marketInfo.totalVolumeB == 0) {
            // Refund the user's bets
            payout = userBet.amountA + userBet.amountB;
        } else {
            // Normal case: calculate winnings based on outcome
            uint256 userWinningBet;
            uint256 totalWinningPool;
            uint256 totalPool = marketInfo.totalVolumeA + marketInfo.totalVolumeB;

            if (marketInfo.outcome == MarketOutcome.OPTION_A) {
                userWinningBet = userBet.amountA;
                totalWinningPool = marketInfo.totalVolumeA;
            } else if (marketInfo.outcome == MarketOutcome.OPTION_B) {
                userWinningBet = userBet.amountB;
                totalWinningPool = marketInfo.totalVolumeB;
            }

            if (userWinningBet > 0 && totalWinningPool > 0) {
                // Winner gets proportional share of the total pool
                payout = (userWinningBet * totalPool) / totalWinningPool;
            }
        }

        if (payout > 0) {
            token.safeTransfer(msg.sender, payout);
        }

        emit WinningsClaimed(msg.sender, payout);
    }

    /**
     * @notice Calculate potential winnings for a bet amount
     */
    function calculatePotentialWinnings(bool _betOnA, uint256 _betAmount) 
        external 
        view 
        returns (uint256 potentialWinnings, uint256 netBetAmount) 
    {
        // Calculate net bet amount after fees
        uint256 totalFees = (_betAmount * 15) / 100;
        netBetAmount = _betAmount - totalFees;
        
        uint256 newTotalPool;
        uint256 newWinningPool;
        
        if (_betOnA) {
            newTotalPool = marketInfo.totalVolumeA + marketInfo.totalVolumeB + netBetAmount;
            newWinningPool = marketInfo.totalVolumeA + netBetAmount;
        } else {
            newTotalPool = marketInfo.totalVolumeA + marketInfo.totalVolumeB + netBetAmount;
            newWinningPool = marketInfo.totalVolumeB + netBetAmount;
        }
        
        if (newWinningPool == 0) {
            potentialWinnings = 0;
        } else {
            // Calculate what user would win if they bet this amount
            potentialWinnings = (netBetAmount * newTotalPool) / newWinningPool;
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
            // Odds represent payout multiplier - inverse of implied probability
            oddsA = (marketInfo.totalVolumeB * 1e6) / totalVolume; 
            oddsB = (marketInfo.totalVolumeA * 1e6) / totalVolume;
        }
    }

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
            uint256 totalBets
        ) 
    {
        return (
            marketInfo.totalVolumeA,
            marketInfo.totalVolumeB,
            marketInfo.totalVolumeA + marketInfo.totalVolumeB,
            marketInfo.creatorFee,
            marketInfo.factoryFee,
            totalBetCount
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