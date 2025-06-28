// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract USDTFaucet is Ownable, ReentrancyGuard {
    IERC20 public usdtToken;
    
    // Amount of tokens to give per claim (50 USDT with 6 decimals)
    uint256 public constant CLAIM_AMOUNT = 50 * 10**6;
    
    // Time delay between claims (24 hours)
    uint256 public constant CLAIM_DELAY = 24 hours;
    
    // Mapping to track last claim time for each user
    mapping(address => uint256) public lastClaimTime;
    
    // Events
    event TokensClaimed(address indexed user, uint256 amount, uint256 timestamp);
    event FaucetRefilled(uint256 amount);
    event EmergencyWithdraw(uint256 amount);
    
    constructor(address _usdtTokenAddress) Ownable(msg.sender) {
        require(_usdtTokenAddress != address(0), "Invalid token address");
        usdtToken = IERC20(_usdtTokenAddress);
    }
    
    /**
     * @dev Allows users to claim 50 USDT tokens every 24 hours
     */
    function claimTokens() external nonReentrant {
        require(canClaim(msg.sender), "Cannot claim yet. Wait 24 hours since last claim");
        require(getFaucetBalance() >= CLAIM_AMOUNT, "Insufficient faucet balance");
        
        // Update last claim time
        lastClaimTime[msg.sender] = block.timestamp;
        
        // Transfer tokens to user
        require(usdtToken.transfer(msg.sender, CLAIM_AMOUNT), "Token transfer failed");
        
        emit TokensClaimed(msg.sender, CLAIM_AMOUNT, block.timestamp);
    }
    
    /**
     * @dev Check if user can claim tokens
     * @param user Address of the user
     * @return bool True if user can claim, false otherwise
     */
    function canClaim(address user) public view returns (bool) {
        return block.timestamp >= lastClaimTime[user] + CLAIM_DELAY;
    }
    
    /**
     * @dev Get time remaining until next claim for a user
     * @param user Address of the user
     * @return uint256 Time in seconds until next claim (0 if can claim now)
     */
    function getTimeUntilNextClaim(address user) public view returns (uint256) {
        if (canClaim(user)) {
            return 0;
        }
        return (lastClaimTime[user] + CLAIM_DELAY) - block.timestamp;
    }
    
    /**
     * @dev Get current faucet balance
     * @return uint256 Current balance of USDT tokens in the faucet
     */
    function getFaucetBalance() public view returns (uint256) {
        return usdtToken.balanceOf(address(this));
    }
    
    /**
     * @dev Owner can refill the faucet with tokens
     * @param amount Amount of tokens to add to faucet
     */
    function refillFaucet(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        require(usdtToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        emit FaucetRefilled(amount);
    }
    
    /**
     * @dev Emergency function to withdraw all tokens (owner only)
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = getFaucetBalance();
        require(balance > 0, "No tokens to withdraw");
        
        require(usdtToken.transfer(owner(), balance), "Transfer failed");
        
        emit EmergencyWithdraw(balance);
    }
    
    /**
     * @dev Get user's last claim time
     * @param user Address of the user
     * @return uint256 Timestamp of last claim
     */
    function getLastClaimTime(address user) external view returns (uint256) {
        return lastClaimTime[user];
    }
    
    /**
     * @dev Check if faucet has enough tokens for a claim
     * @return bool True if faucet has enough tokens
     */
    function hasSufficientBalance() external view returns (bool) {
        return getFaucetBalance() >= CLAIM_AMOUNT;
    }
}