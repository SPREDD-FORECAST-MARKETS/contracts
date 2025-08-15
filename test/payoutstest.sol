// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";

// Interfaces for querying
interface IWeeklyForecastPointManager {
    function getCurrentWeekUserFP(address user) external view returns (uint256 traderFP, uint256 creatorFP, uint256 totalWeeklyFP);
    function getUserFPHistory(address user, uint256 week) external view returns (uint256 traderFP, uint256 creatorFP, uint256 totalWeeklyFP);
    function getWeeklyLeaderboard(uint256 week) external view returns (address[] memory users, uint256[] memory fpAmounts);
    function currentWeek() external view returns (uint256);
    function getTopK() external view returns (uint256);
    function topK() external view returns (uint256);
    function rewardToken() external view returns (address);
}

interface ISpreddMarket {
    function getMarketInfo() external view returns (
        string memory question,
        string memory optionA,
        string memory optionB,
        uint256 endTime,
        address creator,
        bool resolved,
        uint8 outcome
    );
    
    function getMarketVolumes() external view returns (
        uint256 totalVolumeA,
        uint256 totalVolumeB,
        uint256 totalVolume,
        uint256 claimedVolumeA,
        uint256 claimedVolumeB,
        uint256 totalBets,
        bool resolved
    );
    
    function getUserBets(address user) external view returns (uint256 betA, uint256 betB);
    function getUserWinnings(address user) external view returns (uint256 originalBet, uint256 winnings, uint256 totalPayout, bool canClaim);
    function getMarketOdds() external view returns (uint256 oddsA, uint256 oddsB, uint256 totalPool);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

contract QueryResults is Script {
    event LeaderboardRank(uint256 rank, address user, uint256 fpAmount);
    // Contract addresses from your deployment
    address constant USDT_ADDRESS = 0xe416Ca51756C1D72962ACe29c2Af8922798a7c02;
    address constant FP_MANAGER_ADDRESS = 0x6825154951D03904274303BaE2224d6AB6665537;
    address constant FACTORY_ADDRESS = 0xA3727EaA504E9628e8Cd88a377Fc3C11f4828f8d;
    address constant MARKET_ADDRESS = 0xe12987598a7022dc0489aC329e287c51e77835bE;
    address constant TEST_USER = 0x50b8821d4De797a629Ab6E2489A2DFe888b461E5;
    
    function run() external view {
        console.log("=== SPREDD MARKET RESULTS ANALYSIS ===\n");
        
        // 1. Check Market Details
        _queryMarketDetails();
        
        // 2. Check User Results (Winners/Losers)
        _queryUserResults();
        
        // 3. Check Leaderboards
        _queryLeaderboards();
        
        // 4. Check Financial Summary
        _queryFinancialSummary();
    }
    
    function _queryMarketDetails() internal view {
        console.log(" MARKET DETAILS:");
        console.log("================");
        
        ISpreddMarket market = ISpreddMarket(MARKET_ADDRESS);
        
        // Market info
        (string memory question, string memory optionA, string memory optionB, 
         uint256 endTime, address creator, bool resolved, uint8 outcome) = market.getMarketInfo();
        
        console.log("Question:", question);
        console.log("Option A:", optionA);
        console.log("Option B:", optionB);
        console.log("Creator:", creator);
        console.log("Resolved:", resolved);
        
        if (resolved) {
            if (outcome == 1) {
                console.log("Winner: Option A");
            } else if (outcome == 2) {
                console.log("Winner: Option B");
            } else {
                console.log("Winner: Draw/Cancelled");
            }
        }
        
        // Market volumes
        (uint256 volumeA, uint256 volumeB, uint256 totalVolume, 
         uint256 claimedA, uint256 claimedB, uint256 totalBets,) = market.getMarketVolumes();
        
        console.log("BETTING VOLUMES:");
        console.log("Volume A:", volumeA / 1e6, "USDT");
        console.log("Volume B:", volumeB / 1e6, "USDT");
        console.log("Total Volume:", totalVolume / 1e6, "USDT");
        console.log("Total Bets:", totalBets);
        console.log("Claimed A:", claimedA / 1e6, "USDT");
        console.log("Claimed B:", claimedB / 1e6, "USDT");
        
        // Odds
        (uint256 oddsA, uint256 oddsB,) = market.getMarketOdds();
        console.log("FINAL ODDS:");
        console.log("Odds A:", (oddsA * 100) / 1000000, "%");
        console.log("Odds B:", (oddsB * 100) / 1000000, "%");
        
        console.log("\n");
    }
    
    function _queryUserResults() internal view {
        console.log("USER RESULTS:");
        console.log("===============");
        
        ISpreddMarket market = ISpreddMarket(MARKET_ADDRESS);
        IERC20 usdt = IERC20(USDT_ADDRESS);
        
        // Test user results
        console.log("User:", TEST_USER);
        console.log("Current USDT Balance:", usdt.balanceOf(TEST_USER) / 1e6, "USDT");
        
        (uint256 betA, uint256 betB) = market.getUserBets(TEST_USER);
        console.log("Bet on A:", betA / 1e6, "USDT");
        console.log("Bet on B:", betB / 1e6, "USDT");
        console.log("Total Bet:", (betA + betB) / 1e6, "USDT");
        
        (uint256 originalBet, uint256 winnings, uint256 totalPayout, bool canClaim) = market.getUserWinnings(TEST_USER);
        
        if (originalBet > 0) {
            console.log("WINNINGS BREAKDOWN:");
            console.log("Original Winning Bet:", originalBet / 1e6, "USDT");
            console.log("Additional Winnings:", winnings / 1e6, "USDT");
            console.log("Total Payout:", totalPayout / 1e6, "USDT");
            console.log("Can Claim:", canClaim);
            
            // Calculate profit/loss
            uint256 totalBet = betA + betB;
            if (totalPayout > totalBet) {
                console.log("PROFIT:", (totalPayout - totalBet) / 1e6, "USDT");
            } else {
                console.log("LOSS:", (totalBet - totalPayout) / 1e6, "USDT");
            }
        }
        
        console.log("\n");
    }
    
    function _queryLeaderboards() internal view {
        console.log("LEADERBOARDS:");
        console.log("===============");
        
        IWeeklyForecastPointManager fpManager = IWeeklyForecastPointManager(FP_MANAGER_ADDRESS);
        
        uint256 currentWeek = fpManager.currentWeek();
        uint256 topK = fpManager.topK();
        
        console.log("Current Week:", currentWeek);
        console.log("Top K Winners:", topK);
        
        // Get current week user FP
        (uint256 traderFP, uint256 creatorFP, uint256 totalWeeklyFP) = fpManager.getCurrentWeekUserFP(TEST_USER);
        
        console.log("USER FP POINTS:");
        console.log("User:", TEST_USER);
        console.log("Trader FP:", traderFP);
        console.log("Creator FP:", creatorFP);
        console.log("Total Weekly FP:", totalWeeklyFP);
        
        // Try to get leaderboard (might fail if no one else participated)
        try fpManager.getWeeklyLeaderboard(currentWeek) returns (address[] memory users, uint256[] memory fpAmounts) {
            console.log("WEEKLY LEADERBOARD:");
                // Replace with an event or remove the line
                // emit LeaderboardRank(i + 1, users[i], fpAmounts[i]);
                // console.log("Rank", i + 1, ":", users[i], "- FP:", fpAmounts[i]);
            
        } catch {
            console.log("  Leaderboard not available (likely only 1 participant)");
        }
        
        console.log("\n");
    }
    
    function _queryFinancialSummary() internal view {
        console.log("FINANCIAL SUMMARY:");
        console.log("====================");
        
        IERC20 usdt = IERC20(USDT_ADDRESS);
        
        // Contract balances
        console.log("Contract Balances:");
        console.log("- USDT Token:", usdt.balanceOf(USDT_ADDRESS) / 1e6, "USDT");
        console.log("- FP Manager:", usdt.balanceOf(FP_MANAGER_ADDRESS) / 1e6, "USDT");
        console.log("- Factory:", usdt.balanceOf(FACTORY_ADDRESS) / 1e6, "USDT");
        console.log("- Market:", usdt.balanceOf(MARKET_ADDRESS) / 1e6, "USDT");
        
        // User balance
        console.log("\nUser Balance:");
        console.log("- Test User:", usdt.balanceOf(TEST_USER) / 1e6, "USDT");
        
        console.log("FEES COLLECTED:");
        console.log("- Market Creation Fee: 1 USDT");
        console.log("- Creator Fee: 60 USDT (2% of volume)");
        console.log("- FP Manager Fee: 300 USDT (10% of volume)");
        console.log("- Factory Fee: 30 USDT (1% of volume)");
        console.log("- Total Fees: 391 USDT");
        
        console.log("\n=== ANALYSIS COMPLETE ===");
    }
}

// Simplified query for just leaderboard
contract QuickLeaderboardCheck is Script {
    function run() external view {
        IWeeklyForecastPointManager fpManager = IWeeklyForecastPointManager(0x6825154951D03904274303BaE2224d6AB6665537);
        
        console.log(" QUICK LEADERBOARD CHECK:");
        
        uint256 currentWeek = fpManager.currentWeek();
        console.log("Current Week:", currentWeek);
        
        address testUser = 0x50b8821d4De797a629Ab6E2489A2DFe888b461E5;
        (uint256 traderFP, uint256 creatorFP, uint256 totalWeeklyFP) = fpManager.getCurrentWeekUserFP(testUser);
        
        console.log("Test User FP:");
        console.log("- Trader FP:", traderFP);
        console.log("- Creator FP:", creatorFP);
        console.log("- Total FP:", totalWeeklyFP);
    }
}




// scripts


// forge script test/testScript.sol:DeployToBaseSepolia --rpc-url base_sepolia --broadcast --verify -vvvv --tc DeployToBaseSepolia
// forge script test/testScript.sol:TestOnBaseSepolia --rpc-url base_sepolia --broadcast --verify -vvvv --tc TestOnBaseSepolia
// forge script QueryResults --rpc-url base_sepolia -vv