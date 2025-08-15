// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/v2/SpreddFactory.sol";
import "../src/v2/SpreddMarket.sol";
import "../src/FPManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
contract MintTestTokens is Script {
    function run() external {
        address usdtAddress = vm.envAddress("USDT_ADDRESS");
        address recipient = vm.envAddress("RECIPIENT_ADDRESS");
        uint256 amount = vm.envUint("MINT_AMOUNT") * 10**6; // Amount in USDT
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        USDT usdt = USDT(usdtAddress);
        usdt.faucet(recipient, amount);
        
        vm.stopBroadcast();
        
        console.log("Minted", amount / 10**6, "USDT to", recipient);
        console.log("New balance:", usdt.balanceOf(recipient) / 10**6, "USDT");
    }
}