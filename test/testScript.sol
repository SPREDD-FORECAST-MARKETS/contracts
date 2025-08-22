// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/v2/SpreddFactory.sol";
import "../src/v2/SpreddMarket.sol";
import "../src/FPManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock USDT Token for testing on Base Sepolia
contract USDT is ERC20 {
    constructor(uint256 initialSupply) ERC20("Tether USD", "USDT") {
        _mint(msg.sender, initialSupply * (10**6));
    }

    // Override decimals to 6
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    // Add a faucet function for testnet
    function faucet(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployToBaseSepolia is Script {
    // Deployment addresses will be logged
    USDT public usdt;
    WeeklyForecastPointManager public fpManager;
    SpreddMarketFactory public factory;
    
    function run() external {
        // Get deployer from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying to Base Sepolia...");
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance / 1e18, "ETH");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy contracts
        _deployContracts();
        
        // Setup contracts
        _setupContracts();
        
        // Mint initial tokens for testing
        _mintTestTokens(deployer);
        
        vm.stopBroadcast();
        
        // Log deployment info
        _logDeploymentInfo();
        
        console.log("\n=== DEPLOYMENT COMPLETED SUCCESSFULLY ===");
    }
    
    function _deployContracts() internal {
        console.log("\n--- Deploying Contracts ---");
        
        // Deploy USDT with 10M initial supply
        usdt = new USDT(10_000_000); // 10M USDT
        console.log("USDT deployed at:", address(usdt));
        
        // Deploy FP Manager (Top 10 rewards, USDT as reward token)
        fpManager = new WeeklyForecastPointManager(10, address(usdt));
        console.log("FP Manager deployed at:", address(fpManager));
        
        // Deploy Factory
        factory = new SpreddMarketFactory(address(usdt));
        console.log("Factory deployed at:", address(factory));
    }
    
    function _setupContracts() internal {
        console.log("\n--- Setting up Contracts ---");
        
        // Set FP Manager in factory
        factory.setFPManager(address(fpManager));
        console.log("FP Manager set in Factory");
        
        // Set factory in FP Manager
        fpManager.setSpreddFactory(address(factory));
        console.log("Factory set in FP Manager");
        
        // For testnet, set deployer as initial leaderboard manager
        fpManager.setLeaderboardManager(msg.sender);
        console.log("Leaderboard manager set to deployer");
    }
    
    function _mintTestTokens(address deployer) internal {
        console.log("\n--- Minting Test Tokens ---");
        
        // Mint additional tokens for testing (1M USDT)
        usdt.faucet(deployer, 1_000_000 * 10**6);
        console.log("Minted 1M USDT to deployer for testing");
        
        // Log deployer's USDT balance
        uint256 balance = usdt.balanceOf(deployer);
        console.log("Deployer USDT balance:", balance / 10**6, "USDT");
    }
    
    function _logDeploymentInfo() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base Sepolia");
        console.log("Chain ID: 84532");
        console.log("");
        console.log("Contract Addresses:");
        console.log("USDT Token:", address(usdt));
        console.log("FP Manager:", address(fpManager));
        console.log("Factory:", address(factory));
        console.log("");
        console.log("USDT Token Info:");
        console.log("- Name:", usdt.name());
        console.log("- Symbol:", usdt.symbol());
        console.log("- Decimals:", usdt.decimals());
        console.log("- Total Supply:", usdt.totalSupply() / 10**6, "USDT");
        console.log("");
        console.log("Factory Info:");
        console.log("- Trading Token:", factory.tradingToken());
        console.log("- Market Creation Fee:", factory.getMarketCreationFee() / 10**6, "USDT");
        console.log("- Total Markets:", factory.getMarketCount());
        console.log("");
        console.log("FP Manager Info:");
        console.log("- Reward Token:", address(fpManager.rewardToken()));
        console.log("- Current Week:", fpManager.currentWeek());
        console.log("- Top K:", fpManager.topK());
    }
}

// Separate script for testing on Base Sepolia
contract TestOnBaseSepolia is Script {
    // Contract addresses (will be read from environment or previous deployment)
    address public usdtAddress;
    address public fpManagerAddress;
    address public factoryAddress;
    
    // Test accounts
    address public deployer;
    address public creator;
    address public trader1;
    address public trader2;
    address public trader3;
    
    // Contract instances
    USDT public usdt;
    WeeklyForecastPointManager public fpManager;
    SpreddMarketFactory public factory;
    SpreddMarket public market;
    
    // Test parameters
    uint256 public constant BET_AMOUNT = 1000 * 10**6; // 1000 USDT
    // uint256 public constant MARKET_CREATION_FEE = 100 * 10**6; // 100 USDT
    
    function run() external {
        // Read contract addresses from environment or use hardcoded ones
        _loadContractAddresses();
        
        // Setup test accounts
        _setupTestAccounts();
        
        // Initialize contract instances
        _initializeContracts();
        
        // Run comprehensive test
        _runTestFlow();
    }
    
    function _loadContractAddresses() internal {
        // You can set these in .env file or hardcode after deployment
        usdtAddress = vm.envOr("USDT_ADDRESS", address(0));
        fpManagerAddress = vm.envOr("FP_MANAGER_ADDRESS", address(0));
        factoryAddress = vm.envOr("FACTORY_ADDRESS", address(0));
        
        require(usdtAddress != address(0), "USDT address not set");
        require(fpManagerAddress != address(0), "FP Manager address not set");
        require(factoryAddress != address(0), "Factory address not set");
        
        console.log("Using contract addresses:");
        console.log("USDT:", usdtAddress);
        console.log("FP Manager:", fpManagerAddress);
        console.log("Factory:", factoryAddress);
    }
    
    function _setupTestAccounts() internal {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        // For testnet, we'll use the same account with different nonces
        // In production, you'd use different private keys
        creator = deployer;
        trader1 = deployer;
        trader2 = deployer;
        trader3 = deployer;
        
        console.log("Test accounts setup:");
        console.log("Deployer/Tester:", deployer);
    }
    
    function _initializeContracts() internal {
        usdt = USDT(usdtAddress);
        fpManager = WeeklyForecastPointManager(fpManagerAddress);
        factory = SpreddMarketFactory(payable(factoryAddress));
        
        console.log("Contract instances initialized");
    }
    
    function _runTestFlow() internal {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("\n=== STARTING BASE SEPOLIA TEST FLOW ===");
        
        // 1. Create Market
        _testCreateMarket();
        
        // 2. Place Bets (simulated with multiple transactions)
        _testPlaceBets();
        
        // 3. Resolve Market
        _testResolveMarket();
        
        // 4. Claim Winnings
        _testClaimWinnings();
        
        vm.stopBroadcast();
        
        console.log("\n=== BASE SEPOLIA TEST COMPLETED ===");
    }
    
    function _testCreateMarket() internal {
        console.log("\n--- Creating Market on Base Sepolia ---");
        
        // Check and approve tokens for market creation
        uint256 balance = usdt.balanceOf(deployer);
        console.log("USDT balance before creation:", balance / 10**6, "USDT");
        
        // Approve factory
    uint256 actualMarketCreationFee = factory.getMarketCreationFee();
        console.log("Required market creation fee:", actualMarketCreationFee / 10**6, "USDT");
            usdt.approve(address(factory), actualMarketCreationFee);        
        // Create market
        (bytes32 marketId, address marketAddress) = factory.createMarket(
            "Will ETH reach $5000 by end of 2024?",
            "Yes, ETH will reach $5000",
            "No, ETH will not reach $5000",
            block.timestamp + 7 days
        );
        
        market = SpreddMarket(marketAddress);
        
        console.log("Market created successfully!");
        console.log("Market ID:", vm.toString(abi.encode(marketId)));
        console.log("Market Address:", marketAddress);
        
        // Verify on explorer
        console.log("View on BaseScan:");
        console.log("Market Contract:", string.concat("https://sepolia.basescan.org/address/", vm.toString(marketAddress)));
        console.log("Factory Contract:", string.concat("https://sepolia.basescan.org/address/", vm.toString(address(factory))));
    }
    
    function _testPlaceBets() internal {
        console.log("\n--- Placing Bets on Base Sepolia ---");
        
        // For testnet, we'll place multiple bets from the same account
        // In production, these would be from different accounts
        
        // Approve market for betting
        usdt.approve(address(market), BET_AMOUNT * 3);
        
        // Bet 1: 1000 USDT on Option A
        market.placeBet(true, BET_AMOUNT);
        console.log("Bet 1 placed: 1000 USDT on Option A");
        
        // Bet 2: 500 USDT on Option B  
        market.placeBet(false, BET_AMOUNT / 2);
        console.log("Bet 2 placed: 500 USDT on Option B");
        
        // Bet 3: 1500 USDT on Option A
        market.placeBet(true, BET_AMOUNT + BET_AMOUNT / 2);
        console.log("Bet 3 placed: 1500 USDT on Option A");
        
        // Check market state
        (uint256 volumeA, uint256 volumeB, uint256 totalVolume,,,uint256 totalBets,) = market.getMarketVolumes();
        (uint256 oddsA, uint256 oddsB,) = market.getMarketOdds();
        
        console.log("Market State:");
        console.log("Volume A:", volumeA / 10**6, "USDT");
        console.log("Volume B:", volumeB / 10**6, "USDT");
        console.log("Total Volume:", totalVolume / 10**6, "USDT");
        console.log("Total Bets:", totalBets);
        console.log("Odds A:", (oddsA * 100) / 1000000, "%");
        console.log("Odds B:", (oddsB * 100) / 1000000, "%");
    }
    
    function _testResolveMarket() internal {
        console.log("\n--- Resolving Market on Base Sepolia ---");
        
        // Fast forward past market end time (7 days)
        vm.warp(block.timestamp + 8 days);
        
        // Get balances before resolution
        uint256 balanceBefore = usdt.balanceOf(deployer);
        uint256 fpManagerBalanceBefore = usdt.balanceOf(address(fpManager));
        uint256 factoryBalanceBefore = usdt.balanceOf(address(factory));
        
        // Resolve market (Option A wins)
        market.resolveMarket(SpreddMarket.MarketOutcome.OPTION_A);
        
        // Get balances after resolution
        uint256 balanceAfter = usdt.balanceOf(deployer);
        uint256 fpManagerBalanceAfter = usdt.balanceOf(address(fpManager));
        uint256 factoryBalanceAfter = usdt.balanceOf(address(factory));
        
        console.log("Market resolved! Option A wins");
        console.log("Creator fee received:", (balanceAfter - balanceBefore) / 10**6, "USDT");
        console.log("FP Manager fee:", (fpManagerBalanceAfter - fpManagerBalanceBefore) / 10**6, "USDT");
        console.log("Factory fee:", (factoryBalanceAfter - factoryBalanceBefore) / 10**6, "USDT");
        
        // Log transaction for verification
        console.log("Verify resolution on BaseScan:");
        console.log("Market Contract:", string.concat("https://sepolia.basescan.org/address/", vm.toString(address(market))));
    }
    
    function _testClaimWinnings() internal {
        console.log("\n--- Claiming Winnings on Base Sepolia ---");
        
        // Check winnings
        (uint256 originalBet, uint256 winnings, uint256 totalPayout, bool canClaim) = market.getUserWinnings(deployer);
        
        console.log("Winnings calculation:");
        console.log("Original winning bet:", originalBet / 10**6, "USDT");
        console.log("Additional winnings:", winnings / 10**6, "USDT");
        console.log("Total payout:", totalPayout / 10**6, "USDT");
        console.log("Can claim:", canClaim);
        
        if (canClaim) {
            uint256 balanceBefore = usdt.balanceOf(deployer);
            
            // Claim winnings
            market.claimWinnings();
            
            uint256 balanceAfter = usdt.balanceOf(deployer);
            console.log("Winnings claimed:", (balanceAfter - balanceBefore) / 10**6, "USDT");
            
            console.log("Verify claim on BaseScan:");
            console.log("Market Contract:", string.concat("https://sepolia.basescan.org/address/", vm.toString(address(market))));
        }
        
        // Check FP points
        (uint256 traderFP, uint256 creatorFP, uint256 totalWeeklyFP) = fpManager.getCurrentWeekUserFP(deployer);
        // console.log("FP earned - Trader:", traderFP, "Creator:", creatorFP, "Total:", totalWeeklyFP);
    }
}

// Script to mint test tokens on deployed contracts


contract RedeployFactoryWithCorrectUSDT is Script {
    // Your preferred addresses
    address public constant PREFERRED_USDT = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant EXISTING_FP_MANAGER = 0x1cbde05083dFa6BAb8920aF672eB614A9a5E4d66;
    SpreddMarketFactory public newFactory;
    WeeklyForecastPointManager public fpManager;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Redeploying Factory with correct USDT...");
        console.log("Deployer:", deployer);
        console.log("Preferred USDT:", PREFERRED_USDT);
        console.log("Existing FP Manager:", EXISTING_FP_MANAGER);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy new factory with your preferred USDT
        newFactory = new SpreddMarketFactory(PREFERRED_USDT);
        console.log("New Factory deployed at:", address(newFactory));
        
        // Connect to existing FP Manager
        fpManager = WeeklyForecastPointManager(EXISTING_FP_MANAGER);
        
        // Setup connections
        newFactory.setFPManager(EXISTING_FP_MANAGER);
        console.log("FP Manager set in new Factory");
        
        // Update FP Manager to use new factory
        fpManager.setSpreddFactory(address(newFactory));
        console.log("New Factory set in FP Manager");
        
        vm.stopBroadcast();
        
        console.log("\n=== NEW DEPLOYMENT SUMMARY ===");
        console.log("New Factory Address:", address(newFactory));
        console.log("Trading Token:", newFactory.tradingToken());
        // console.log("FP Manager:", newFactory.fpManager());
        console.log("Market Creation Fee:", newFactory.getMarketCreationFee() / 10**6, "USDT");
        
        console.log("\nUpdate your .env file:");
        console.log("FACTORY_ADDRESS=", vm.toString(address(newFactory)));
        console.log("USDT_ADDRESS=", vm.toString(PREFERRED_USDT));
        console.log("FP_MANAGER_ADDRESS=", vm.toString(EXISTING_FP_MANAGER));
    }
}



contract DeployCompleteFreshSetup is Script {
    // Your preferred USDT address
    address public constant PREFERRED_USDT = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    
    WeeklyForecastPointManager public fpManager;
    SpreddMarketFactory public factory;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying complete fresh setup...");
        console.log("Deployer:", deployer);
        console.log("USDT Address:", PREFERRED_USDT);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy FP Manager with your USDT as reward token
        fpManager = new WeeklyForecastPointManager(10, PREFERRED_USDT);
        console.log("New FP Manager deployed at:", address(fpManager));
        
        // Deploy Factory with your USDT as trading token
        factory = new SpreddMarketFactory(PREFERRED_USDT);
        console.log("New Factory deployed at:", address(factory));
        
        // Connect them together (you own both, so this will work)
        factory.setFPManager(address(fpManager));
        console.log("FP Manager set in Factory");
        
        fpManager.setSpreddFactory(address(factory));
        console.log("Factory set in FP Manager");
        
        // Set deployer as leaderboard manager
        fpManager.setLeaderboardManager(deployer);
        console.log("Leaderboard manager set to deployer");
        
        vm.stopBroadcast();
        
        console.log("\n=== FRESH DEPLOYMENT SUMMARY ===");
        console.log("USDT Address:", PREFERRED_USDT);
        console.log("FP Manager Address:", address(fpManager));
        console.log("Factory Address:", address(factory));
        console.log("Owner (you):", deployer);
        
        console.log("\nUpdate your .env file:");
        console.log("USDT_ADDRESS=", vm.toString(PREFERRED_USDT));
        console.log("FP_MANAGER_ADDRESS=", vm.toString(address(fpManager)));
        console.log("FACTORY_ADDRESS=", vm.toString(address(factory)));
        
        console.log("\nContract Details:");
        console.log("- FP Manager reward token:", address(fpManager.rewardToken()));
        console.log("- Factory trading token:", factory.tradingToken());
        console.log("- Market creation fee:", factory.getMarketCreationFee() / 10**6, "USDT");
        console.log("- Current week:", fpManager.currentWeek());
    }
}


contract DeployToBaseMainnet is Script {
    // Base mainnet USDC contract address
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    
    WeeklyForecastPointManager public fpManager;
    SpreddMarketFactory public factory;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying to Base Mainnet...");
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance / 1e18, "ETH");
        console.log("USDC Contract:", BASE_USDC);
        
        // Check USDC balance
        IERC20 usdc = IERC20(BASE_USDC);
        uint256 usdcBalance = usdc.balanceOf(deployer);
        console.log("USDC balance:", usdcBalance / 10**6, "USDC");
        
        require(usdcBalance >= 1 * 10**6, "Need at least 1 USDC for deployment");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy FP Manager with USDC as reward token
        fpManager = new WeeklyForecastPointManager(10, BASE_USDC);
        console.log("FP Manager deployed at:", address(fpManager));
        
        // Deploy Factory with USDC as trading token
        factory = new SpreddMarketFactory(BASE_USDC);
        console.log("Factory deployed at:", address(factory));
        
        // Connect contracts
        factory.setFPManager(address(fpManager));
        console.log("FP Manager set in Factory");
        
        fpManager.setSpreddFactory(address(factory));
        console.log("Factory set in FP Manager");
        
        // Set deployer as leaderboard manager
        fpManager.setLeaderboardManager(deployer);
        console.log("Leaderboard manager set to deployer");
        
        vm.stopBroadcast();
        
        console.log("\n=== BASE MAINNET DEPLOYMENT SUMMARY ===");
        console.log("Network: Base Mainnet");
        console.log("Chain ID: 8453");
        console.log("");
        console.log("Contract Addresses:");
        console.log("USDC Token:", BASE_USDC);
        console.log("FP Manager:", address(fpManager));
        console.log("Factory:", address(factory));
        console.log("");
        console.log("Contract Details:");
        console.log("- FP Manager reward token:", address(fpManager.rewardToken()));
        console.log("- Factory trading token:", factory.tradingToken());
        console.log("- Market creation fee:", factory.getMarketCreationFee() / 10**6, "USDC");
        console.log("- Current week:", fpManager.currentWeek());
        console.log("- Top K setting:", fpManager.topK());
        
        console.log("\nUpdate your .env file:");
        console.log("USDT_ADDRESS=", vm.toString(BASE_USDC));
        console.log("FP_MANAGER_ADDRESS=", vm.toString(address(fpManager)));
        console.log("FACTORY_ADDRESS=", vm.toString(address(factory)));
        
        console.log("\nVerify contracts on BaseScan:");
        console.log("FP Manager:", string.concat("https://basescan.org/address/", vm.toString(address(fpManager))));
        console.log("Factory:", string.concat("https://basescan.org/address/", vm.toString(address(factory))));
    }
}









contract CollectAllTokensScript is Script {
    // Target collection address
    address public constant COLLECTION_ADDRESS = 0xffD7Ea1Cfc86386862Fb5841dFc3D67bC97910b5;
    
    // Contract addresses (set these from your deployment)
    address public factoryAddress;
    address public fpManagerAddress;
    address public tokenAddress;
    
    // Contract instances
    SpreddMarketFactory public factory;
    WeeklyForecastPointManager public fpManager;
    IERC20 public token;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== TOKEN COLLECTION SCRIPT ===");
        console.log("Deployer:", deployer);
        console.log("Collection Address:", COLLECTION_ADDRESS);
        
        // Load contract addresses
        _loadContracts();
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Collect from Factory
        _collectFromFactory();
        
        // 2. Collect from FP Manager
        _collectFromFPManager();
        
        // 3. Collect from all deployed markets
        _collectFromAllMarkets();
        
        vm.stopBroadcast();
        
        // Final balances
        _logFinalBalances();
        
        console.log("\n=== COLLECTION COMPLETED ===");
    }
    
    function _loadContracts() internal {
        // Load from environment or set manually
        factoryAddress = vm.envOr("FACTORY_ADDRESS", address(0));
        fpManagerAddress = vm.envOr("FP_MANAGER_ADDRESS", address(0));
        tokenAddress = vm.envOr("USDT_ADDRESS", address(0));
        
        require(factoryAddress != address(0), "Factory address not set");
        require(fpManagerAddress != address(0), "FP Manager address not set");
        require(tokenAddress != address(0), "Token address not set");
        
        factory = SpreddMarketFactory(payable(factoryAddress));
        fpManager = WeeklyForecastPointManager(fpManagerAddress);
        token = IERC20(tokenAddress);
        
        console.log("\nContract Addresses:");
        console.log("Factory:", factoryAddress);
        console.log("FP Manager:", fpManagerAddress);
        console.log("Token:", tokenAddress);
    }
    
    function _collectFromFactory() internal {
        console.log("\n--- Collecting from Factory ---");
        
        uint256 factoryBalance = token.balanceOf(factoryAddress);
        console.log("Factory token balance:", factoryBalance / 1e6, "USDC");
        
        if (factoryBalance > 0) {
            try factory.withdrawFactoryFees(COLLECTION_ADDRESS) {
                console.log("Factory fees withdrawn to collection address");
            } catch {
                console.log("Failed to withdraw factory fees (might not be owner)");
            }
        } else {
            console.log("No tokens in factory to collect");
        }
    }
    
    function _collectFromFPManager() internal {
        console.log("\n--- Collecting from FP Manager ---");
        
        uint256 fpBalance = token.balanceOf(fpManagerAddress);
        console.log("FP Manager token balance:", fpBalance / 1e6, "USDC");
        
        if (fpBalance > 0) {
            try fpManager.emergencyWithdraw(fpBalance) {
                console.log("FP Manager emergency withdrawal executed");
                
                // Transfer the withdrawn amount to collection address
                uint256 deployerBalance = token.balanceOf(msg.sender);
                if (deployerBalance >= fpBalance) {
                    token.transfer(COLLECTION_ADDRESS, fpBalance);
                    console.log("Transferred", fpBalance / 1e6, "USDC to collection address");
                }
            } catch {
                console.log("Failed to emergency withdraw from FP Manager (might not be owner)");
            }
        } else {
            console.log("No tokens in FP Manager to collect");
        }
    }
    
    function _collectFromAllMarkets() internal {
        console.log("\n--- Collecting from All Markets ---");
        
        // Get all market IDs
        bytes32[] memory allMarkets = factory.getAllMarkets();
        console.log("Total markets found:", allMarkets.length);
        
        uint256 totalCollectedFromMarkets = 0;
        
        for (uint256 i = 0; i < allMarkets.length; i++) {
            bytes32 marketId = allMarkets[i];
            address marketAddress = factory.getMarketAddress(marketId);
            
            if (marketAddress == address(0)) {
                continue;
            }
            
            SpreddMarket market = SpreddMarket(marketAddress);
            uint256 marketBalance = token.balanceOf(marketAddress);
            
            console.log("Market", i, "address:", marketAddress);
            
            if (marketBalance > 0) {
                // Check if market is resolved
                (, , , , , bool resolved, ) = market.getMarketInfo();
                
                if (resolved) {
                    try market.emergencyWithdraw() {
                        console.log("Emergency withdraw from market", i, "successful");
                        totalCollectedFromMarkets += marketBalance;
                    } catch {
                        console.log("Failed to emergency withdraw from market", i, "(might not be owner or not resolved)");
                    }
                } else {
                    console.log("Market", i, "not resolved yet, skipping");
                }
            }
        }
        
        console.log("Total collected from markets:", totalCollectedFromMarkets / 1e6, "USDC");
    }
    
    function _logFinalBalances() internal view {
        console.log("\n--- Final Balances ---");
        console.log("Collection address balance:", token.balanceOf(COLLECTION_ADDRESS) / 1e6, "USDC");
        console.log("Factory balance:", token.balanceOf(factoryAddress) / 1e6, "USDC");
        console.log("FP Manager balance:", token.balanceOf(fpManagerAddress) / 1e6, "USDC");
        
        // Check a few markets
        bytes32[] memory allMarkets = factory.getAllMarkets();
        uint256 totalRemainingInMarkets = 0;
        
        for (uint256 i = 0; i < allMarkets.length && i < 5; i++) {
            address marketAddress = factory.getMarketAddress(allMarkets[i]);
            if (marketAddress != address(0)) {
                uint256 balance = token.balanceOf(marketAddress);
                totalRemainingInMarkets += balance;
         
            }
        }
        
        if (allMarkets.length > 5) {
            for (uint256 i = 5; i < allMarkets.length; i++) {
                address marketAddress = factory.getMarketAddress(allMarkets[i]);
                if (marketAddress != address(0)) {
                    totalRemainingInMarkets += token.balanceOf(marketAddress);
                }
            }
        }
        
        console.log("Total remaining in all markets:", totalRemainingInMarkets / 1e6, "USDC");
    }
}

// Alternative script for more granular control
contract SelectiveTokenCollection is Script {
    address public constant COLLECTION_ADDRESS = 0xffD7Ea1Cfc86386862Fb5841dFc3D67bC97910b5;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address fpManagerAddress = vm.envAddress("FP_MANAGER_ADDRESS");
        address tokenAddress = vm.envAddress("USDT_ADDRESS");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Collect specific amounts or from specific contracts
        _collectSpecificAmount(factoryAddress, fpManagerAddress, tokenAddress);
        
        vm.stopBroadcast();
    }
    
    function _collectSpecificAmount(
        address factoryAddr,
        address fpManagerAddr, 
        address tokenAddr
    ) internal {
        IERC20 token = IERC20(tokenAddr);
        SpreddMarketFactory factory = SpreddMarketFactory(payable(factoryAddr));
        WeeklyForecastPointManager fpManager = WeeklyForecastPointManager(fpManagerAddr);
        
        console.log("=== SELECTIVE COLLECTION ===");
        
        // 1. Collect all from factory
        uint256 factoryBalance = token.balanceOf(factoryAddr);
        if (factoryBalance > 0) {
            factory.withdrawFactoryFees(COLLECTION_ADDRESS);
            console.log("Collected", factoryBalance / 1e6, "USDC from factory");
        }
        
        // 2. Collect specific amount from FP Manager
        uint256 fpBalance = token.balanceOf(fpManagerAddr);
        if (fpBalance > 1000 * 1e6) { // Only if more than 1000 USDC
            fpManager.emergencyWithdraw(fpBalance);
            token.transfer(COLLECTION_ADDRESS, fpBalance);
            console.log("Collected", fpBalance / 1e6, "USDC from FP Manager");
        }
        
        // 3. Collect from specific markets only
        bytes32[] memory markets = factory.getAllMarkets();
        for (uint256 i = 0; i < markets.length; i++) {
            address marketAddr = factory.getMarketAddress(markets[i]);
            uint256 marketBalance = token.balanceOf(marketAddr);
            
            // Only collect from markets with significant balance
            if (marketBalance > 100 * 1e6) { // More than 100 USDC
                SpreddMarket market = SpreddMarket(marketAddr);
                
                try market.emergencyWithdraw() {
                    console.log("Collected", marketBalance / 1e6, "USDC from market", i);
                } catch {
                    console.log("Could not collect from market", i);
                }
            }
        }
    }
}

// Emergency collection script (use with caution)
contract EmergencyTokenSweep is Script {
    address public constant COLLECTION_ADDRESS = 0xffD7Ea1Cfc86386862Fb5841dFc3D67bC97910b5;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== EMERGENCY TOKEN SWEEP ===");
        console.log("WARNING: This will attempt to collect ALL tokens");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Load all contracts
        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        address fpManagerAddr = vm.envAddress("FP_MANAGER_ADDRESS");
        address tokenAddr = vm.envAddress("USDT_ADDRESS");
        
        _sweepAllTokens(factoryAddr, fpManagerAddr, tokenAddr);
        
        vm.stopBroadcast();
        
        console.log("Emergency sweep completed");
    }
    
    function _sweepAllTokens(
        address factoryAddr,
        address fpManagerAddr,
        address tokenAddr
    ) internal {
        IERC20 token = IERC20(tokenAddr);
        SpreddMarketFactory factory = SpreddMarketFactory(payable(factoryAddr));
        WeeklyForecastPointManager fpManager = WeeklyForecastPointManager(fpManagerAddr);
        
        uint256 totalCollected = 0;
        
        // 1. Factory
        try factory.withdrawFactoryFees(COLLECTION_ADDRESS) {
            uint256 collected = token.balanceOf(COLLECTION_ADDRESS);
            totalCollected += collected;
            console.log("Factory swept:", collected / 1e6, "USDC");
        } catch {}
        
        // 2. FP Manager
        try fpManager.emergencyWithdraw(token.balanceOf(fpManagerAddr)) {
            uint256 deployerBalance = token.balanceOf(msg.sender);
            token.transfer(COLLECTION_ADDRESS, deployerBalance);
            totalCollected += deployerBalance;
            console.log("FP Manager swept:", deployerBalance / 1e6, "USDC");
        } catch {}
        
        // 3. All markets
        bytes32[] memory markets = factory.getAllMarkets();
        for (uint256 i = 0; i < markets.length; i++) {
            address marketAddr = factory.getMarketAddress(markets[i]);
            if (marketAddr != address(0)) {
                try SpreddMarket(marketAddr).emergencyWithdraw() {
                    console.log("Market", i, "swept");
                } catch {}
            }
        }
        
        console.log("Total operation completed");
        console.log("Final collection address balance:", token.balanceOf(COLLECTION_ADDRESS) / 1e6, "USDC");
    }
}