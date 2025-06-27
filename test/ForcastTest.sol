// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/Token.sol";
import "../src/SpreddFactory.sol";
import "../src/SpreddMarket.sol";
import "../src/FPManager.sol";

contract ForecastPointTest is Test {
    USDT public usdt;
    WeeklyForecastPointManager public fpManager;
    BinaryPredictionMarketFactory public factory;

    // Test users
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    address public user4 = makeAddr("user4");
    address public user5 = makeAddr("user5");
    
    // Market creators
    address public creator1 = makeAddr("creator1");
    address public creator2 = makeAddr("creator2");
    
    // Market contracts
    BinaryAMMPredictionMarket public market1;
    BinaryAMMPredictionMarket public market2;
    bytes32 public marketId1;
    bytes32 public marketId2;
    
    uint256 constant INITIAL_SUPPLY = 1000000; // 1M USDT
    uint256 constant USER_INITIAL_BALANCE = 100 * 1e6; // 100 USDT per user
    uint256 constant MARKET_DURATION = 7 days;
    uint256 constant INITIAL_LIQUIDITY = 50 * 1e6; // 50 USDT
    
    function setUp() public {
        console.log("=== SETUP PHASE ===");
        
        // Deploy USDT token
        usdt = new USDT(INITIAL_SUPPLY);
        console.log("USDT deployed:", address(usdt));
        
        // Deploy FP Manager with top 10 tracking
        fpManager = new WeeklyForecastPointManager(10);
        console.log("FP Manager deployed:", address(fpManager));
        
        // Deploy Factory
        factory = new BinaryPredictionMarketFactory(address(usdt));
        console.log("Factory deployed:", address(factory));
        
        // Set FP Manager in factory
        factory.setFPManager(address(fpManager));
        
        // Authorize factory in FP Manager
        fpManager.setAuthorizedContract(address(factory), true);
        
        // Distribute USDT to test accounts
        _distributeUSDT();
        
        console.log("Setup completed successfully!");
        console.log("");
    }
    
    function _distributeUSDT() internal {
        address[] memory users = new address[](7);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = user4;
        users[4] = user5;
        users[5] = creator1;
        users[6] = creator2;
        
        for (uint i = 0; i < users.length; i++) {
            usdt.transfer(users[i], USER_INITIAL_BALANCE);
            console.log("Distributed %s USDT to %s", USER_INITIAL_BALANCE / 1e6, users[i]);
        }
    }
    
    function test_CompleteFlowWithTwoMarkets() public {
        console.log("=== STARTING COMPLETE FORECAST POINT TEST ===");
        console.log("");
        
        // Step 1: Create two markets
        _createMarkets();
        
        // Step 2: Initialize markets with liquidity
        _initializeMarkets();
        
        // Step 3: Users make predictions on both markets
        _usersPredictOnMarkets();
        
        // Step 4: Fast forward to market end times
        _fastForwardToMarketEnd();
        
        // Step 5: Resolve markets
        _resolveMarkets();
        
        // Step 6: Check FP awards and rankings
        _checkFPAndRankings();
        
        console.log("=== TEST COMPLETED SUCCESSFULLY ===");
    }
    
    function _createMarkets() internal {
        console.log("=== CREATING MARKETS ===");
        
        // Creator 1 creates Market 1
        vm.startPrank(creator1);
        address market1Addr;
        (marketId1, market1Addr) = factory.createMarket(
            "Will Bitcoin reach $100,000 by end of week?",
            "Yes",
            "No",
            MARKET_DURATION
        );
        market1 = BinaryAMMPredictionMarket(market1Addr);
        console.log("Market 1 created by creator1:", market1Addr);
        vm.stopPrank();
        
        // Creator 2 creates Market 2
        vm.startPrank(creator2);
        address market2Addr;
        (marketId2, market2Addr) = factory.createMarket(
            "Will ETH outperform BTC this week?",
            "ETH wins",
            "BTC wins",
            MARKET_DURATION
        );
        market2 = BinaryAMMPredictionMarket(market2Addr);
        console.log("Market 2 created by creator2:", market2Addr);
        vm.stopPrank();
        
        // Authorize markets in FP Manager
        fpManager.setAuthorizedContract(address(market1), true);
        fpManager.setAuthorizedContract(address(market2), true);
        
        console.log("");
    }
    
    function _initializeMarkets() internal {
        console.log("=== INITIALIZING MARKETS WITH LIQUIDITY ===");
        
        // Initialize Market 1
        vm.startPrank(creator1);
        usdt.approve(address(market1), INITIAL_LIQUIDITY);
        market1.initializeMarket(INITIAL_LIQUIDITY);
        console.log("Market 1 initialized with %s USDT liquidity", INITIAL_LIQUIDITY / 1e6);
        vm.stopPrank();
        
        // Initialize Market 2
        vm.startPrank(creator2);
        usdt.approve(address(market2), INITIAL_LIQUIDITY);
        market2.initializeMarket(INITIAL_LIQUIDITY);
        console.log("Market 2 initialized with %s USDT liquidity", INITIAL_LIQUIDITY / 1e6);
        vm.stopPrank();
        
        console.log("");
    }
    
    function _usersPredictOnMarkets() internal {
        console.log("=== USERS MAKING PREDICTIONS ===");
        
        // Store the initial timestamp when markets were created
        uint256 marketStartTime = block.timestamp;
        
        // Track prediction times for different users (simulate early vs late predictions)
        uint256[] memory delays = new uint256[](5);
        delays[0] = 0;        // user1: immediate (max early bonus)
        delays[1] = 1 hours;  // user2: 1 hour later
        delays[2] = 1 days;   // user3: 1 day later
        delays[3] = 3 days;   // user4: 3 days later
        delays[4] = 5 days;   // user5: 5 days later (but still within market duration)
        
        address[] memory users = new address[](5);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = user4;
        users[4] = user5;
        
        for (uint i = 0; i < users.length; i++) {
            // Set time to market start + user's delay (instead of accumulating delays)
            vm.warp(marketStartTime + delays[i]);
            
            address user = users[i];
            uint256 betAmount = (i + 1) * 1 * 1e6; // Varying bet sizes: 5, 10, 15, 20, 25 USDT
            
            console.log("User %s betting %s USDT after %s hours", i+1, betAmount / 1e6, delays[i] / 3600);
            
            vm.startPrank(user);
            
            // Market 1 predictions
            usdt.approve(address(market1), betAmount);
            bool buyOptionA1 = (i % 2 == 0); // Users 1,3,5 bet on Option A; Users 2,4 bet on Option B
            market1.buyTokens(buyOptionA1, betAmount, 0);
            
            string memory option1 = buyOptionA1 ? "Yes (Option A)" : "No (Option B)";
            console.log("  Market 1: Bet on %s", option1);
            
            // Market 2 predictions (different pattern)
            usdt.approve(address(market2), betAmount);
            bool buyOptionA2 = (i < 2); // Users 1,2 bet on Option A; Users 3,4,5 bet on Option B
            market2.buyTokens(buyOptionA2, betAmount, 0);
            
            string memory option2 = buyOptionA2 ? "ETH wins (Option A)" : "BTC wins (Option B)";
            console.log("  Market 2: Bet on %s", option2);
            
            vm.stopPrank();
            
            // Show user's current position
            (uint256 optionA1, uint256 optionB1,) = market1.getUserBalances(user);
            (uint256 optionA2, uint256 optionB2,) = market2.getUserBalances(user);
            // console.log("  Positions - Market1: A=%s B=%s | Market2: A=%s B=%s", 
            //            optionA1 / 1e6, optionB1 / 1e6, optionA2 / 1e6, optionB2 / 1e6);
            console.log("");
        }
        
        // Reset to just after the last user's prediction for next steps
        vm.warp(marketStartTime + delays[4] + 1 hours);
    }
    
    function _fastForwardToMarketEnd() internal {
        console.log("=== FAST FORWARDING TO MARKET END ===");
        
        // Fast forward to after market end time (from the original market creation time)
        vm.warp(block.timestamp + MARKET_DURATION - 5 days + 1 hours); // Add remaining time + 1 hour buffer
        console.log("Time advanced to after market closure");
        console.log("");
    }
    
    function _resolveMarkets() internal {
        console.log("=== RESOLVING MARKETS ===");
        
        // Resolve Market 1: Option A wins (Yes - Bitcoin reaches $100k)
        vm.prank(creator1);
        market1.resolveMarket(BinaryAMMPredictionMarket.MarketOutcome.OPTION_A);
        console.log("Market 1 resolved: Option A (Yes) wins!");
        console.log("Winners: user1, user3, user5");
        
        // Resolve Market 2: Option B wins (BTC outperforms ETH)
        vm.prank(creator2);
        market2.resolveMarket(BinaryAMMPredictionMarket.MarketOutcome.OPTION_B);
        console.log("Market 2 resolved: Option B (BTC wins) wins!");
        console.log("Winners: user3, user4, user5");
        
        console.log("");
    }
    
    function _checkFPAndRankings() internal {
        console.log("=== FORECAST POINT RESULTS ===");
        console.log("");
        
        // Check individual user FP
        address[] memory users = new address[](5);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = user4;
        users[4] = user5;
        
        string[] memory userNames = new string[](5);
        userNames[0] = "User1";
        userNames[1] = "User2";
        userNames[2] = "User3";
        userNames[3] = "User4";
        userNames[4] = "User5";
        
        console.log("INDIVIDUAL USER FP BREAKDOWN:");
        console.log("----------------------------------------");
        
        for (uint i = 0; i < users.length; i++) {
            (uint256 traderFP, uint256 creatorFP, uint256 totalFP) = fpManager.getCurrentWeekUserFP(users[i]);
            console.log("%s:", userNames[i]);
            console.log("  Trader FP: %s", traderFP);
            console.log("  Creator FP: %s", creatorFP);
            console.log("  Total FP: %s", totalFP);
            
            // Show winning positions for context
            (uint256 optionA1, uint256 optionB1,) = market1.getUserBalances(users[i]);
            (uint256 optionA2, uint256 optionB2,) = market2.getUserBalances(users[i]);
            
            bool wonMarket1 = optionA1 > 0; // Market 1 Option A won
            bool wonMarket2 = optionB2 > 0; // Market 2 Option B won
            
            console.log("  Market 1 win: %s", wonMarket1 ? "YES" : "NO");
            console.log("  Market 2 win: %s", wonMarket2 ? "YES" : "NO");
            console.log("");
        }
        
        // Check creator FP
        console.log("CREATOR FP:");
        console.log("----------------------------------------");
        (uint256 creator1TraderFP, uint256 creator1CreatorFP, uint256 creator1TotalFP) = fpManager.getCurrentWeekUserFP(creator1);
        (uint256 creator2TraderFP, uint256 creator2CreatorFP, uint256 creator2TotalFP) = fpManager.getCurrentWeekUserFP(creator2);
        
        console.log("Creator1 (Market 1):");
        console.log("  Trader FP: %s", creator1TraderFP);
        console.log("  Creator FP: %s", creator1CreatorFP);
        console.log("  Total FP: %s", creator1TotalFP);
        
        console.log("Creator2 (Market 2):");
        console.log("  Trader FP: %s", creator2TraderFP);
        console.log("  Creator FP: %s", creator2CreatorFP);
        console.log("  Total FP: %s", creator2TotalFP);
        console.log("");
        
        // Get current week rankings
        console.log("CURRENT WEEK RANKINGS:");
        console.log("----------------------------------------");
        
        (address[] memory topTraders, uint256[] memory traderFPs, 
         address[] memory topCreators, uint256[] memory creatorFPs) = fpManager.getCurrentWeekTopPerformers(10);
        
        console.log("TOP TRADERS:");
        for (uint i = 0; i < topTraders.length; i++) {
            string memory userName = _getAddressName(topTraders[i]);
            console.log("  Rank %s: %s with %s FP", i + 1, userName, traderFPs[i]);
        }
        console.log("");
        
        console.log("TOP CREATORS:");
        for (uint i = 0; i < topCreators.length; i++) {
            string memory creatorName = _getAddressName(topCreators[i]);
            console.log("  Rank %s: %s with %s FP", i + 1, creatorName, creatorFPs[i]);
        }
        console.log("");
        
        // Verify expected results
        console.log("VERIFICATION:");
        console.log("----------------------------------------");
        
        // User3 should have highest trader FP (won both markets)
        (uint256 user3TraderFP,,) = fpManager.getCurrentWeekUserFP(user3);
        bool user3IsTop = true;
        for (uint i = 0; i < users.length; i++) {
            if (users[i] != user3) {
                (uint256 otherTraderFP,,) = fpManager.getCurrentWeekUserFP(users[i]);
                if (otherTraderFP > user3TraderFP) {
                    user3IsTop = false;
                    break;
                }
            }
        }
        
        console.log("User3 won both markets - should have highest trader FP: %s", user3IsTop ? "PASS" : "FAIL");
        
        // User1 should have good FP (early prediction, won 1 market)
        (uint256 user1TraderFP,,) = fpManager.getCurrentWeekUserFP(user1);
        console.log("User1 early prediction bonus (won Market 1): %s", user1TraderFP > 0 ? "PASS" : "FAIL");
        
        // User2 and User4 should have 0 trader FP (lost both markets)
        (uint256 user2TraderFP,,) = fpManager.getCurrentWeekUserFP(user2);
        (uint256 user4TraderFP,,) = fpManager.getCurrentWeekUserFP(user4);
        console.log("User2 lost both markets (0 trader FP): %s", user2TraderFP == 0 ? "PASS" : "FAIL");
        console.log("User4 lost both markets (0 trader FP): %s", user4TraderFP == 0 ? "PASS" : "FAIL");
        
        // Show market trading activity
        console.log("");
        console.log("MARKET STATISTICS:");
        console.log("----------------------------------------");
        (, , , , , , , uint256 market1Trades, uint256 market1Users,) = market1.getMarketInfoWithFP();
        (, , , , , , , uint256 market2Trades, uint256 market2Users,) = market2.getMarketInfoWithFP();
        
        console.log("Market 1 - Total trades: %s | Unique users: %s", market1Trades, market1Users);
        console.log("Market 2 - Total trades: %s | Unique users: %s", market2Trades, market2Users);
        
        uint256 totalVolume1 = market1.getTotalValue();
        uint256 totalVolume2 = market2.getTotalValue();
        console.log("Market 1 total volume: %s USDT", totalVolume1 / 1e6);
        console.log("Market 2 total volume: %s USDT", totalVolume2 / 1e6);
    }
    
    function _getAddressName(address addr) internal view returns (string memory) {
        if (addr == user1) return "User1";
        if (addr == user2) return "User2";
        if (addr == user3) return "User3";
        if (addr == user4) return "User4";
        if (addr == user5) return "User5";
        if (addr == creator1) return "Creator1";
        if (addr == creator2) return "Creator2";
        return "Unknown";
    }
    
    // Helper function to check specific FP calculation components
    function test_FPCalculationComponents() public view {
        console.log("=== FP CALCULATION COMPONENT PREVIEW ===");
        
        // Preview trader FP calculation for different scenarios
        uint256 marketVolume = 100 * 1e6; // 100 USDT
        uint256 positionSize = 10 * 1e6;  // 10 USDT bet
        uint256 marketDuration = 7 days;
        
        // Early prediction (1 hour after creation)
        (uint256 earlyFP, uint256 earlyMarketWeight, uint256 earlyBonus, uint256 earlyCorrectness) = 
            fpManager.previewTraderFP(
                marketVolume,
                1 hours,           // position time
                0,                 // market creation time
                marketDuration,
                40 * 1e6,         // correct side liquidity
                100 * 1e6,        // total liquidity
                positionSize
            );
            
        console.log("Early prediction (1 hour) FP components:");
        console.log("  Market weight: %s", earlyMarketWeight);
        console.log("  Early bonus: %s", earlyBonus);
        console.log("  Correctness multiplier: %s", earlyCorrectness);
        console.log("  Total FP: %s", earlyFP);
        
        // Late prediction (5 days after creation)
        (uint256 lateFP, uint256 lateMarketWeight, uint256 lateBonus, uint256 lateCorrectness) = 
            fpManager.previewTraderFP(
                marketVolume,
                5 days,           // position time
                0,                // market creation time
                marketDuration,
                40 * 1e6,        // correct side liquidity
                100 * 1e6,       // total liquidity
                positionSize
            );
            
        console.log("Late prediction (5 days) FP components:");
        console.log("  Market weight: %s", lateMarketWeight);
        console.log("  Early bonus: %s", lateBonus);
        console.log("  Correctness multiplier: %s", lateCorrectness);
        console.log("  Total FP: %s", lateFP);
        
        // Creator FP preview
        (uint256 creatorTotalFP, uint256 baseFP, uint256 volumeBonus, uint256 activityBonus) = 
            fpManager.previewCreatorFP(marketVolume, 5); // 5 trades
            
        console.log("Creator FP components (100 USDT volume, 5 trades):");
        console.log("  Base FP: %s", baseFP);
        console.log("  Volume bonus: %s", volumeBonus);
        console.log("  Activity bonus: %s", activityBonus);
        console.log("  Total FP: %s", creatorTotalFP);
    }
}