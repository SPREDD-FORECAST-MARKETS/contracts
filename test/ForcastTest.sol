// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.17;

// import "forge-std/Test.sol";
// import "../src/SpreddMarketFactory.sol";
// import "../src/SpreddMarket.sol";
// import "../src/FPManager.sol";
// import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// // Mock USDT Token for testing
// contract USDT is ERC20 {
//     constructor(uint256 initialSupply) ERC20("Tether USD", "USDT") {
//         _mint(msg.sender, initialSupply * (10**6));
//     }

//     // Override decimals to 6
//     function decimals() public pure override returns (uint8) {
//         return 6;
//     }
// }

// contract SpreddMarketTest is Test {
//     // Contracts
//     USDT public usdt;
//     WeeklyForecastPointManager public fpManager;
//     SpreddMarketFactory public factory;
//     SpreddMarket public market;
    
//     // Test accounts
//     address public owner = address(this);
//     address public creator = address(0x1);
//     address public trader1 = address(0x2);
//     address public trader2 = address(0x3);
//     address public trader3 = address(0x4);
//     address public leaderboardManager = address(0x5);
    
//     // Test data
//     uint256 public constant INITIAL_SUPPLY = 1000000; // 1M USDT
//     uint256 public constant MARKET_CREATION_FEE = 100 * 10**6; // 100 USDT
//     uint256 public constant BET_AMOUNT = 1000 * 10**6; // 1000 USDT
    
//     bytes32 public marketId;
//     address public marketAddress;
    
//     event log_named_decimal_uint(string key, uint256 val, uint256 decimals);

//     function setUp() public {
//         // Deploy USDT token
//         usdt = new USDT(INITIAL_SUPPLY);
        
//         // Deploy FP Manager
//         fpManager = new WeeklyForecastPointManager(10, address(usdt)); // Top 10, USDT rewards
        
//         // Deploy Factory
//         factory = new SpreddMarketFactory(address(usdt));
        
//         // Set FP Manager in factory
//         factory.setFPManager(address(fpManager));
        
//         // Set factory in FP Manager
//         fpManager.setSpreddFactory(address(factory));
        
//         // Set leaderboard manager
//         fpManager.setLeaderboardManager(leaderboardManager);
        
//         // Distribute USDT to test accounts
//         _distributeTokens();
        
//         console.log("=== SETUP COMPLETE ===");
//         console.log("USDT deployed at:", address(usdt));
//         console.log("FP Manager deployed at:", address(fpManager));
//         console.log("Factory deployed at:", address(factory));
//         _logBalances("After Setup");
//     }

//     function _distributeTokens() internal {
//         uint256 amount = 50000 * 10**6; // 50k USDT each
        
//         usdt.transfer(creator, amount);
//         usdt.transfer(trader1, amount);
//         usdt.transfer(trader2, amount);
//         usdt.transfer(trader3, amount);
//         usdt.transfer(leaderboardManager, amount);
        
//         // Approve factory for market creation fees
//         vm.prank(creator);
//         usdt.approve(address(factory), MARKET_CREATION_FEE);
//     }

//     function testCompleteFlow() public {
//         console.log("\n=== STARTING COMPLETE FLOW TEST ===");
        
//         // 1. Create Market
//         _testCreateMarket();
        
//         // 2. Place Bets
//         _testPlaceBets();
        
//         // 3. Resolve Market
//         _testResolveMarket();
        
//         // 4. Claim Winnings
//         _testClaimWinnings();
        
//         // 5. Test FP Distribution
//         _testFPDistribution();
        
//         // 6. Test Weekly Reset and Rewards
//         _testWeeklyRewards();
        
//         console.log("\n=== ALL TESTS COMPLETED SUCCESSFULLY ===");
//     }

//     function _testCreateMarket() internal {
//         console.log("\n--- Testing Market Creation ---");
        
//         vm.startPrank(creator);
        
//         // Create market
//         (bytes32 _marketId, address _marketAddress) = factory.createMarket(
//             "Will Bitcoin reach $100k by end of 2024?",
//             "Yes, Bitcoin will reach $100k",
//             "No, Bitcoin will not reach $100k",
//             block.timestamp + 7 days
//         );
        
//         marketId = _marketId;
//         marketAddress = _marketAddress;
//         market = SpreddMarket(marketAddress);
        
//         vm.stopPrank();
        
//         // Verify market creation
//         assertTrue(factory.marketExists(marketId));
//         assertEq(factory.getMarketAddress(marketId), marketAddress);
        
//         // Log market info
//         (string memory question, string memory optionA, string memory optionB, uint256 endTime, , bool resolved,) = market.getMarketInfo();
        
//         console.log("Market created successfully!");
//         console.log("Market ID:", vm.toString(abi.encode(marketId)));
//         console.log("Market Address:", marketAddress);
//         console.log("Question:", question);
//         console.log("Option A:", optionA);
//         console.log("Option B:", optionB);
//         console.log("End Time:", endTime);
//         console.log("Resolved:", resolved);
        
//         _logBalances("After Market Creation");
//     }

//     function _testPlaceBets() internal {
//         console.log("\n--- Testing Bet Placement ---");
        
//         // Approve market for betting
//         vm.prank(trader1);
//         usdt.approve(marketAddress, BET_AMOUNT);
        
//         vm.prank(trader2);
//         usdt.approve(marketAddress, BET_AMOUNT);
        
//         vm.prank(trader3);
//         usdt.approve(marketAddress, BET_AMOUNT * 2);
        
//         // Trader 1: Bet on Option A
//         vm.prank(trader1);
//         market.placeBet(true, BET_AMOUNT); // Option A
        
//         // Trader 2: Bet on Option B
//         vm.prank(trader2);
//         market.placeBet(false, BET_AMOUNT); // Option B
        
//         // Trader 3: Bet on Option A (higher amount)
//         vm.prank(trader3);
//         market.placeBet(true, BET_AMOUNT * 2); // Option A
        
//         // Check market volumes
//         (uint256 volumeA, uint256 volumeB, uint256 totalVolume, , , uint256 totalBets,) = market.getMarketVolumes();
        
//         console.log("Bets placed successfully!");
//         console.log("Volume A:", volumeA / 10**6, "USDT");
//         console.log("Volume B:", volumeB / 10**6, "USDT");
//         console.log("Total Volume:", totalVolume / 10**6, "USDT");
//         console.log("Total Bets:", totalBets);
        
//         // Check odds
//         (uint256 oddsA, uint256 oddsB,) = market.getMarketOdds();
//         console.log("Odds A:", oddsA, "/ 1000000 (", (oddsA * 100) / 1000000, "%)");
//         console.log("Odds B:", oddsB, "/ 1000000 (", (oddsB * 100) / 1000000, "%)");
        
//         _logBalances("After Betting");
//     }

//     function _testResolveMarket() internal {
//         console.log("\n--- Testing Market Resolution ---");
        
//         // Fast forward past market end time
//         vm.warp(block.timestamp + 8 days);
        
//         // Get balances before resolution
//         uint256 creatorBalanceBefore = usdt.balanceOf(creator);
//         uint256 factoryBalanceBefore = usdt.balanceOf(address(factory));
//         uint256 fpManagerBalanceBefore = usdt.balanceOf(address(fpManager));
        
//         // Resolve market (Option A wins)
//         vm.prank(creator);
//         market.resolveMarket(SpreddMarket.MarketOutcome.OPTION_A);
        
//         // Get balances after resolution
//         uint256 creatorBalanceAfter = usdt.balanceOf(creator);
//         uint256 factoryBalanceAfter = usdt.balanceOf(address(factory));
//         uint256 fpManagerBalanceAfter = usdt.balanceOf(address(fpManager));
        
//         // Calculate fees
//         uint256 totalPool = 4000 * 10**6; // Total bet volume
//         uint256 expectedCreatorFee = (totalPool * 2) / 100; // 2%
//         uint256 expectedFactoryFee = (totalPool * 1) / 100; // 1%
//         uint256 expectedRewardPoolFee = (totalPool * 10) / 100; // 10%
        
//         console.log("Market resolved successfully!");
//         console.log("Winning option: A");
//         console.log("Creator fee received:", (creatorBalanceAfter - creatorBalanceBefore) / 10**6, "USDT");
//         console.log("Factory fee received:", (factoryBalanceAfter - factoryBalanceBefore) / 10**6, "USDT");
//         console.log("FP Manager fee received:", (fpManagerBalanceAfter - fpManagerBalanceBefore) / 10**6, "USDT");
        
//         // Verify fee distribution
//         assertEq(creatorBalanceAfter - creatorBalanceBefore, expectedCreatorFee);
//         assertEq(factoryBalanceAfter - factoryBalanceBefore, expectedFactoryFee);
//         assertEq(fpManagerBalanceAfter - fpManagerBalanceBefore, expectedRewardPoolFee);
        
//         console.log("Expected creator fee:", expectedCreatorFee / 10**6, "USDT");
//         console.log("Expected factory fee:", expectedFactoryFee / 10**6, "USDT");
//         console.log("Expected reward pool fee:", expectedRewardPoolFee / 10**6, "USDT");
        
//         _logBalances("After Market Resolution");
//     }

//     function _testClaimWinnings() internal {
//         console.log("\n--- Testing Winnings Claims ---");
        
//         // Get winning pool size
//         uint256 winningPoolSize = market.getWinningPoolSize();
//         console.log("Winning pool size:", winningPoolSize / 10**6, "USDT");
        
//         // Check winnings for each trader
//         (uint256 originalBet1, uint256 winnings1, uint256 totalPayout1, bool canClaim1) = market.getUserWinnings(trader1);
//         (uint256 originalBet2, uint256 winnings2, uint256 totalPayout2, bool canClaim2) = market.getUserWinnings(trader2);
//         (uint256 originalBet3, uint256 winnings3, uint256 totalPayout3, bool canClaim3) = market.getUserWinnings(trader3);
        
//         console.log("Trader1 (Option A winner):");
//         console.log("  Original bet:", originalBet1 / 10**6, "USDT");
//         console.log("  Winnings:", winnings1 / 10**6, "USDT");
//         console.log("  Total payout:", totalPayout1 / 10**6, "USDT");
//         console.log("  Can claim:", canClaim1);
        
//         console.log("Trader2 (Option B loser):");
//         console.log("  Original bet:", originalBet2 / 10**6, "USDT");
//         console.log("  Winnings:", winnings2 / 10**6, "USDT");
//         console.log("  Total payout:", totalPayout2 / 10**6, "USDT");
//         console.log("  Can claim:", canClaim2);
        
//         console.log("Trader3 (Option A winner):");
//         console.log("  Original bet:", originalBet3 / 10**6, "USDT");
//         console.log("  Winnings:", winnings3 / 10**6, "USDT");
//         console.log("  Total payout:", totalPayout3 / 10**6, "USDT");
//         console.log("  Can claim:", canClaim3);
        
//         // Claim winnings for winners
//         uint256 trader1BalanceBefore = usdt.balanceOf(trader1);
//         uint256 trader3BalanceBefore = usdt.balanceOf(trader3);
        
//         if (canClaim1) {
//             vm.prank(trader1);
//             market.claimWinnings();
//             console.log("Trader1 claimed winnings successfully");
//         }
        
//         if (canClaim3) {
//             vm.prank(trader3);
//             market.claimWinnings();
//             console.log("Trader3 claimed winnings successfully");
//         }
        
//         uint256 trader1BalanceAfter = usdt.balanceOf(trader1);
//         uint256 trader3BalanceAfter = usdt.balanceOf(trader3);
        
//         console.log("Trader1 received:", (trader1BalanceAfter - trader1BalanceBefore) / 10**6, "USDT");
//         console.log("Trader3 received:", (trader3BalanceAfter - trader3BalanceBefore) / 10**6, "USDT");
        
//         _logBalances("After Claims");
//     }

//     function _testFPDistribution() internal {
//         console.log("\n--- Testing FP Distribution ---");
        
//         // Check current week FP for all users
//         (uint256 creatorTraderFP, uint256 creatorCreatorFP,) = fpManager.getCurrentWeekUserFP(creator);
//         (uint256 trader1TraderFP, uint256 trader1CreatorFP,) = fpManager.getCurrentWeekUserFP(trader1);
//         (uint256 trader2TraderFP, uint256 trader2CreatorFP,) = fpManager.getCurrentWeekUserFP(trader2);
//         (uint256 trader3TraderFP, uint256 trader3CreatorFP,) = fpManager.getCurrentWeekUserFP(trader3);
        
//         console.log("FP Distribution:");
//         console.log("Creator - Trader FP:", creatorTraderFP, "Creator FP:", creatorCreatorFP);
//         console.log("Trader1 - Trader FP:", trader1TraderFP, "Creator FP:", trader1CreatorFP);
//         console.log("Trader2 - Trader FP:", trader2TraderFP, "Creator FP:", trader2CreatorFP);
//         console.log("Trader3 - Trader FP:", trader3TraderFP, "Creator FP:", trader3CreatorFP);
        
//         // Get current week info
//         (uint256 currentWeek, uint256 startTime, uint256 endTime, uint256 tradersCount, uint256 creatorsCount, uint256 topK, uint256 currentRewardPool) = fpManager.getCurrentWeekInfo();
        
//         console.log("Current Week Info:");
//         console.log("Week:", currentWeek);
//         console.log("Traders Count:", tradersCount);
//         console.log("Creators Count:", creatorsCount);
//         console.log("Current Reward Pool:", currentRewardPool / 10**6, "USDT");
//     }

//     function _testWeeklyRewards() internal {
//         console.log("\n--- Testing Weekly Rewards ---");
        
//         // Fast forward to end of week
//         vm.warp(block.timestamp + 7 days);
        
//         // Trigger week end by trying to award FP (this will call manualWeeklyUpdate)
//         vm.prank(address(market));
//         fpManager.awardCreatorFP(creator, marketId, 0, 0);
        
//         // Check week status
//         (uint256 currentWeek,,,,,, uint256 currentRewardPool) = fpManager.getCurrentWeekInfo();
//         console.log("Current week after time advancement:", currentWeek);
//         console.log("Current reward pool:", currentRewardPool / 10**6, "USDT");
        
//         // Get pending weeks
//         (uint256[] memory pendingWeeks, uint256[] memory rewardPools) = fpManager.getPendingWeeks();
        
//         if (pendingWeeks.length > 0) {
//             console.log("Pending weeks found:", pendingWeeks.length);
//             console.log("Week 1 reward pool:", rewardPools[0] / 10**6, "USDT");
            
//             // Simulate off-chain leaderboard calculation and submission
//             _simulateLeaderboardSubmission(pendingWeeks[0], rewardPools[0]);
//         }
//     }

//     function _simulateLeaderboardSubmission(uint256 week, uint256 rewardPool) internal {
//         console.log("\n--- Simulating Leaderboard Submission ---");
        
//         // Get historical FP data for the week
//         (uint256 trader1FP,,) = fpManager.getUserWeeklyFP(trader1, week);
//         (uint256 trader3FP,,) = fpManager.getUserWeeklyFP(trader3, week);
//         (uint256 creatorFP,,) = fpManager.getUserWeeklyFP(creator, week);
        
//         console.log("Week", week, "FP Summary:");
//         console.log("Trader1 FP:", trader1FP);
//         console.log("Trader3 FP:", trader3FP);
//         console.log("Creator FP:", creatorFP);
        
//         // Create sorted arrays (trader3 should be first due to higher winning amount)
//         address[] memory topTraders = new address[](2);
//         uint256[] memory traderFPs = new uint256[](2);
        
//         if (trader3FP >= trader1FP) {
//             topTraders[0] = trader3;
//             topTraders[1] = trader1;
//             traderFPs[0] = trader3FP;
//             traderFPs[1] = trader1FP;
//         } else {
//             topTraders[0] = trader1;
//             topTraders[1] = trader3;
//             traderFPs[0] = trader1FP;
//             traderFPs[1] = trader3FP;
//         }
        
//         address[] memory topCreators = new address[](1);
//         uint256[] memory creatorFPs = new uint256[](1);
//         topCreators[0] = creator;
//         creatorFPs[0] = creatorFP;
        
//         // Get balances before reward distribution
//         uint256 trader1BalanceBefore = usdt.balanceOf(trader3);
//         uint256 trader2BalanceBefore = usdt.balanceOf(trader1);
        
//         // Submit leaderboard as leaderboard manager
//         vm.prank(leaderboardManager);
//         fpManager.submitWeeklyLeaderboard(
//             week,
//             topTraders,
//             traderFPs,
//             topCreators,
//             creatorFPs
//         );
        
//         // Get balances after reward distribution
//         uint256 trader1BalanceAfter = usdt.balanceOf(trader3);
//         uint256 trader2BalanceAfter = usdt.balanceOf(trader1);
        
//         console.log("Weekly rewards distributed!");
//         console.log("Top trader (trader3) received:", (trader1BalanceAfter - trader1BalanceBefore) / 10**6, "USDT");
//         console.log("Second trader (trader1) received:", (trader2BalanceAfter - trader2BalanceBefore) / 10**6, "USDT");
        
//         // Check weekly winners
//         (address[] memory weeklyTopTraders, uint256[] memory weeklyTraderFP, uint256[] memory weeklyTraderRewards, , , uint256 totalDistributed) = fpManager.getWeeklyWinners(week);
        
//         console.log("Weekly winners summary:");
//         console.log("Total distributed:", totalDistributed / 10**6, "USDT");
//         for (uint256 i = 0; i < weeklyTopTraders.length; i++) {
//             console.log("Rank", i+1, ":", weeklyTopTraders[i], "- FP:", weeklyTraderFP[i], "- Reward:", weeklyTraderRewards[i] / 10**6, "USDT");
//         }
        
//         _logBalances("After Weekly Rewards");
//     }

//     function _logBalances(string memory stage) internal view {
//         console.log("\n--- Balances", stage, "---");
//         console.log("Owner:", usdt.balanceOf(owner) / 10**6, "USDT");
//         console.log("Creator:", usdt.balanceOf(creator) / 10**6, "USDT");
//         console.log("Trader1:", usdt.balanceOf(trader1) / 10**6, "USDT");
//         console.log("Trader2:", usdt.balanceOf(trader2) / 10**6, "USDT");
//         console.log("Trader3:", usdt.balanceOf(trader3) / 10**6, "USDT");
//         console.log("Factory:", usdt.balanceOf(address(factory)) / 10**6, "USDT");
//         console.log("FP Manager:", usdt.balanceOf(address(fpManager)) / 10**6, "USDT");
//         if (address(market) != address(0)) {
//             console.log("Market:", usdt.balanceOf(address(market)) / 10**6, "USDT");
//         }
//     }

//     // Additional test functions for edge cases
//     function testMarketCreationFee() public {
//         console.log("\n=== Testing Market Creation Fee ===");
        
//         uint256 creationFee = factory.getMarketCreationFee();
//         console.log("Current creation fee:", creationFee / 10**6, "USDT");
        
//         // Test fee collection
//         uint256 factoryBalanceBefore = usdt.balanceOf(address(factory));
        
//         vm.startPrank(creator);
//         usdt.approve(address(factory), creationFee);
        
//         factory.createMarket(
//             "Test market for fee",
//             "Option A",
//             "Option B",
//             block.timestamp + 1 days
//         );
//         vm.stopPrank();
        
//         uint256 factoryBalanceAfter = usdt.balanceOf(address(factory));
//         console.log("Factory fee collected:", (factoryBalanceAfter - factoryBalanceBefore) / 10**6, "USDT");
        
//         assertEq(factoryBalanceAfter - factoryBalanceBefore, creationFee);
//     }

//     function testFactoryStats() public {
//         console.log("\n=== Testing Factory Stats ===");
        
//         (uint256 totalMarkets, uint256 totalTVL, uint256 activeMarkets, uint256 totalBets, uint256 totalBettors) = factory.getMarketStats();
        
//         console.log("Factory Statistics:");
//         console.log("Total Markets:", totalMarkets);
//         console.log("Total TVL:", totalTVL / 10**6, "USDT");
//         console.log("Active Markets:", activeMarkets);
//         console.log("Total Bets:", totalBets);
//         console.log("Total Bettors:", totalBettors);
        
//         assertTrue(totalMarkets > 0);
//         assertTrue(totalTVL > 0);
//     }

//     function testFPManagerEmergencyFunctions() public {
//         console.log("\n=== Testing FP Manager Emergency Functions ===");
        
//         // Test force weekly reset
//         vm.prank(owner);
//         fpManager.forceWeeklyReset();
        
//         console.log("Force weekly reset executed successfully");
        
//         // Test emergency withdraw
//         uint256 fpBalance = usdt.balanceOf(address(fpManager));
//         if (fpBalance > 0) {
//             uint256 ownerBalanceBefore = usdt.balanceOf(owner);
            
//             vm.prank(owner);
//             fpManager.emergencyWithdraw(fpBalance);
            
//             uint256 ownerBalanceAfter = usdt.balanceOf(owner);
//             console.log("Emergency withdraw executed:", (ownerBalanceAfter - ownerBalanceBefore) / 10**6, "USDT");
//         }
//     }

//     // Test helper functions
//     receive() external payable {}
// }