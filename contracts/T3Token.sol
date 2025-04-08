// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title T3Token
 * @dev ERC20 token with HalfLife mechanism, transfer reversal capabilities, and tiered logarithmic fee structure
 */
contract T3Token is ERC20, Ownable {
    // Fee structure constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant TIER_MULTIPLIER = 10;
    uint256 private constant BASE_FEE_PERCENT = 1000 * BASIS_POINTS; // 1000% for first tier
    uint256 private constant MIN_FEE = 1; // Minimum fee in token units
    uint256 private constant MAX_FEE_PERCENT = 5 * BASIS_POINTS; // Maximum 5% fee cap
    
    // HalfLife constants
    uint256 public halfLifeDuration = 3600; // Default 1 hour in seconds
    uint256 public minHalfLifeDuration = 600; // Minimum 10 minutes
    uint256 public maxHalfLifeDuration = 86400; // Maximum 24 hours
    uint256 public inactivityResetPeriod = 30 days;
    
    // Treasury address
    address public treasuryAddress;
    
    // Data structures
    struct TransferMetadata {
        uint256 commitWindowEnd;
        uint256 halfLifeDuration;
        address originator;
        uint256 transferCount;
        bytes32 reversalHash;
        uint256 feeAmount;
        bool isReversed;
    }
    
    struct RollingAverage {
        uint256 totalAmount;
        uint256 count;
        uint256 lastUpdated;
    }
    
    struct WalletRiskProfile {
        uint256 reversalCount;
        uint256 lastReversal;
        uint256 creationTime;
        uint256 abnormalTxCount;
    }
    
    struct IncentiveCredits {
        uint256 amount;
        uint256 lastUpdated;
    }
    
    // Mappings
    mapping(address => TransferMetadata) public transferData;
    mapping(address => RollingAverage) public rollingAverages;
    mapping(address => mapping(address => uint256)) public transactionCountBetween;
    mapping(address => WalletRiskProfile) public walletRiskProfiles;
    mapping(address => IncentiveCredits) public incentiveCredits;
    
    // Events
    event TransferWithFee(address indexed from, address indexed to, uint256 amount, uint256 fee);
    event TransferReversed(address indexed from, address indexed to, uint256 amount);
    event HalfLifeExpired(address indexed wallet, uint256 timestamp);
    event LoyaltyRefundProcessed(address indexed wallet, uint256 amount);
    event RiskFactorUpdated(address indexed wallet, uint256 newRiskFactor);
    
    /**
     * @dev Constructor
     * @param initialOwner The address that will receive the initial token supply
     * @param _treasuryAddress The address that will receive treasury fees
     */
    constructor(address initialOwner, address _treasuryAddress) ERC20("T3 Stablecoin", "T3") Ownable(initialOwner) {
        require(_treasuryAddress != address(0), "Treasury address cannot be zero");
        treasuryAddress = _treasuryAddress;
        
        // Mint initial supply to owner
        _mint(initialOwner, 1000000 * 10**decimals());
        
        // Initialize owner's wallet risk profile
        walletRiskProfiles[initialOwner].creationTime = block.timestamp;
    }
    
    /**
     * @dev Override transfer function to include fee calculation and HalfLife mechanism
     * @param recipient The recipient address
     * @param amount The amount to transfer
     * @return bool Success indicator
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        require(recipient != address(0), "Transfer to zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        
        // Check if sender is in HalfLife period and not the originator
        if (transferData[_msgSender()].commitWindowEnd > block.timestamp && 
            transferData[_msgSender()].originator != recipient) {
            revert("Cannot transfer during HalfLife period except back to originator");
        }
        
        // Calculate fee using tiered logarithmic structure
        uint256 feeAmount = calculateTieredFee(amount);
        
        // Apply risk adjustments
        feeAmount = applyRiskAdjustments(feeAmount, _msgSender(), recipient);
        
        // Apply credits to reduce fee
        feeAmount = applyCredits(_msgSender(), feeAmount);
        
        // Ensure fee doesn't exceed maximum percentage
        uint256 maxFeeAmount = (amount * MAX_FEE_PERCENT) / BASIS_POINTS;
        if (feeAmount > maxFeeAmount) {
            feeAmount = maxFeeAmount;
        }
        
        // Ensure fee meets minimum
        if (feeAmount < MIN_FEE && amount > MIN_FEE) {
            feeAmount = MIN_FEE;
        }
        
        // Transfer tokens (amount minus fee)
        uint256 netAmount = amount - feeAmount;
        _transfer(_msgSender(), recipient, netAmount);
        
        // Process fee distribution if fee exists
        if (feeAmount > 0) {
            processFee(_msgSender(), recipient, amount, feeAmount);
        }
        
        // Update transaction count between sender and recipient
        transactionCountBetween[_msgSender()][recipient]++;
        
        // Calculate adaptive HalfLife duration
        uint256 adaptiveHalfLife = calculateAdaptiveHalfLife(_msgSender(), recipient, amount);
        
        // Set transfer metadata
        transferData[recipient] = TransferMetadata({
            commitWindowEnd: block.timestamp + adaptiveHalfLife,
            halfLifeDuration: adaptiveHalfLife,
            originator: _msgSender(),
            transferCount: transferData[recipient].transferCount + 1,
            reversalHash: keccak256(abi.encodePacked(_msgSender(), recipient, amount)),
            feeAmount: feeAmount,
            isReversed: false
        });
        
        // Update rolling average for recipient
        updateRollingAverage(recipient, amount);
        
        emit TransferWithFee(_msgSender(), recipient, netAmount, feeAmount);
        return true;
    }
    
    /**
     * @dev Calculate fee using tiered logarithmic structure
     * @param amount The transaction amount
     * @return The calculated fee
     */
    function calculateTieredFee(uint256 amount) public pure returns (uint256) {
        if (amount == 0) return 0;
        
        uint256 remainingAmount = amount;
        uint256 totalFee = 0;
        uint256 tierCeiling = 1;
        uint256 tierFloor = 0;
        uint256 currentFeePercent = BASE_FEE_PERCENT;
        
        // Process each tier until we've covered the full amount
        while (remainingAmount > 0) {
            uint256 amountInTier;
            
            if (remainingAmount > (tierCeiling - tierFloor)) {
                amountInTier = tierCeiling - tierFloor;
                remainingAmount -= amountInTier;
            } else {
                amountInTier = remainingAmount;
                remainingAmount = 0;
            }
            
            // Calculate fee for this tier
            uint256 tierFee = (amountInTier * currentFeePercent) / BASIS_POINTS;
            totalFee += tierFee;
            
            // Move to next tier
            tierFloor = tierCeiling;
            tierCeiling = tierCeiling * TIER_MULTIPLIER;
            currentFeePercent = currentFeePercent / TIER_MULTIPLIER;
            
            // If fee percentage becomes too small, stop calculating
            if (currentFeePercent == 0) break;
        }
        
        return totalFee;
    }
    
    /**
     * @dev Apply risk adjustments to the base fee
     * @param baseFee The base fee calculated from the tiered structure
     * @param sender The sender address
     * @param recipient The recipient address
     * @return The risk-adjusted fee
     */
    function applyRiskAdjustments(uint256 baseFee, address sender, address recipient) public view returns (uint256) {
        uint256 senderRiskFactor = calculateRiskFactor(sender);
        uint256 recipientRiskFactor = calculateRiskFactor(recipient);
        
        // Use the higher risk factor
        uint256 riskFactor = senderRiskFactor > recipientRiskFactor ? senderRiskFactor : recipientRiskFactor;
        
        // Apply risk factor (as a percentage)
        return (baseFee * riskFactor) / BASIS_POINTS;
    }
    
    /**
     * @dev Calculate risk factor for a wallet
     * @param wallet The wallet address
     * @return The risk factor (in basis points, where 10000 = 100%)
     */
    function calculateRiskFactor(address wallet) public view returns (uint256) {
        WalletRiskProfile storage profile = walletRiskProfiles[wallet];
        
        // Base risk factor starts at 100% (10000 basis points)
        uint256 riskFactor = BASIS_POINTS;
        
        // New wallet penalty (less than 7 days old)
        if (profile.creationTime > 0 && block.timestamp - profile.creationTime < 7 days) {
            riskFactor += 5000; // +50%
        }
        
        // Recent reversal penalty
        if (profile.lastReversal > 0 && block.timestamp - profile.lastReversal < 30 days) {
            riskFactor += 10000; // +100%
        }
        
        // Reversal count penalty
        riskFactor += profile.reversalCount * 1000; // +10% per reversal
        
        // Abnormal transaction penalty
        riskFactor += profile.abnormalTxCount * 500; // +5% per abnormal transaction
        
        return riskFactor;
    }
    
    /**
     * @dev Apply available credits to reduce fee
     * @param wallet The wallet address
     * @param fee The fee amount
     * @return The reduced fee amount
     */
    function applyCredits(address wallet, uint256 fee) public returns (uint256) {
        IncentiveCredits storage credits = incentiveCredits[wallet];
        
        if (credits.amount == 0) {
            return fee;
        }
        
        if (credits.amount >= fee) {
            // Full fee coverage
            credits.amount -= fee;
            credits.lastUpdated = block.timestamp;
            return 0;
        } else {
            // Partial fee coverage
            uint256 remainingFee = fee - credits.amount;
            credits.amount = 0;
            credits.lastUpdated = block.timestamp;
            return remainingFee;
        }
    }
    
    /**
     * @dev Process fee distribution between treasury and incentive pools
     * @param sender The sender address
     * @param recipient The recipient address
     * @param amount The original transfer amount
     * @param feeAmount The fee amount
     */
    function processFee(address sender, address recipient, uint256 amount, uint256 feeAmount) internal {
        // 50% to treasury
        uint256 treasuryShare = feeAmount / 2;
        _mint(treasuryAddress, treasuryShare);
        
        // 25% to sender's incentive pool
        uint256 senderShare = feeAmount / 4;
        incentiveCredits[sender].amount += senderShare;
        incentiveCredits[sender].lastUpdated = block.timestamp;
        
        // 25% to recipient's incentive pool
        uint256 recipientShare = feeAmount - treasuryShare - senderShare; // Account for rounding
        incentiveCredits[recipient].amount += recipientShare;
        incentiveCredits[recipient].lastUpdated = block.timestamp;
    }
    
    /**
     * @dev Calculate adaptive HalfLife duration based on transaction patterns
     * @param sender The sender address
     * @param recipient The recipient address
     * @param amount The transfer amount
     * @return The adaptive HalfLife duration
     */
    function calculateAdaptiveHalfLife(address sender, address recipient, uint256 amount) internal view returns (uint256) {
        uint256 duration = halfLifeDuration;
        
        // Reduce HalfLife for frequent transactions between the same parties
        uint256 txCount = transactionCountBetween[sender][recipient];
        if (txCount > 0) {
            // Reduce by 10% for each previous transaction, up to 90% reduction
            uint256 reduction = (txCount * 10 > 90) ? 90 : txCount * 10;
            duration = duration * (100 - reduction) / 100;
        }
        
        // Increase HalfLife for abnormally large transactions
        RollingAverage storage avg = rollingAverages[sender];
        if (avg.count > 0) {
            uint256 avgAmount = avg.totalAmount / avg.count;
            if (amount > avgAmount * 10) {
                // Double the HalfLife for transactions 10x larger than average
                duration = duration * 2;
            }
        }
        
        // Ensure within min/max bounds
        if (duration < minHalfLifeDuration) {
            duration = minHalfLifeDuration;
        } else if (duration > maxHalfLifeDuration) {
            duration = maxHalfLifeDuration;
        }
        
        return duration;
    }
    
    /**
     * @dev Update rolling average for a wallet
     * @param wallet The wallet address
     * @param amount The transaction amount
     */
    function updateRollingAverage(address wallet, uint256 amount) internal {
        RollingAverage storage avg = rollingAverages[wallet];
        
        // Reset if inactive for too long
        if (avg.lastUpdated > 0 && block.timestamp - avg.lastUpdated > inactivityResetPeriod) {
            avg.totalAmount = 0;
            avg.count = 0;
        }
        
        // Update the average
        avg.totalAmount += amount;
        avg.count++;
        avg.lastUpdated = block.timestamp;
    }
    
    /**
     * @dev Reverse a transfer within the HalfLife period
     * @param from The current holder address
     * @param to The original sender address
     * @param amount The amount to reverse
     */
    function reverseTransfer(address from, address to, uint256 amount) external {
        TransferMetadata memory meta = transferData[from];
        
        require(msg.sender == from || msg.sender == to, "Only sender or receiver can reverse");
        require(block.timestamp < meta.commitWindowEnd, "HalfLife expired");
        require(to == meta.originator, "Reversal must go back to originator");
        require(balanceOf(from) >= amount, "Insufficient balance to reverse");
        
        // Mark the transfer as reversed
        transferData[from].isReversed = true;
        
        // Update wallet risk profiles
        updateWalletRiskProfile(from, true, false);
        updateWalletRiskProfile(to, true, false);
        
        // Transfer tokens back
        _transfer(from, to, amount);
        
        // Prevent reversal of reversal
        delete transferData[from];
        
        emit TransferReversed(from, to, amount);
    }
    
    /**
     * @dev Check if HalfLife period has expired and process loyalty refunds
     * @param wallet The wallet address to check
     */
    function checkHalfLifeExpiry(address wallet) external {
        TransferMetadata storage meta = transferData[wallet];
        
        require(meta.commitWindowEnd > 0, "No active transfer data");
        require(block.timestamp >= meta.commitWindowEnd, "HalfLife not expired yet");
        require(!meta.isReversed, "Transfer was reversed");
        
        // Process loyalty refunds if not already processed
        if (meta.feeAmount > 0) {
            // 25% refund to both parties
            uint256 senderRefund = meta.feeAmount / 8; // 25% of sender's 50% share
            uint256 recipientRefund = meta.feeAmount / 8; // 25% of recipient's 50% share
            
            // Credit the refunds
            incentiveCredits[meta.originator].amount += senderRefund;
            incentiveCredits[meta.originator].lastUpdated = block.timestamp;
            
            incentiveCredits[wallet].amount += recipientRefund;
            incentiveCredits[wallet].lastUpdated = block.timestamp;
            
            emit LoyaltyRefundProcessed(meta.originator, senderRefund);
            emit LoyaltyRefundProcessed(wallet, recipientRefund);
        }
        
        // Update wallet risk profiles positively
        updateWalletRiskProfile(wallet, false, true);
        updateWalletRiskProfile(meta.originator, false, true);
        
        // Clear the metadata
        delete transferData[wallet];
        
        emit HalfLifeExpired(wallet, block.timestamp);
    }
    
    /**
     * @dev Update wallet risk profile
     * @param wallet The wallet address
     * @param isReversal Whether this is a reversal event
     * @param isSuccessful Whether this is a successful transaction
     */
    function updateWalletRiskProfile(address wallet, bool isReversal, bool isSuccessful) internal {
        WalletRiskProfile storage profile = walletRiskProfiles[wallet];
        
        // Initialize creation time if not set
        if (profile.creationTime == 0) {
            profile.creationTime = block.timestamp;
        }
        
        if (isReversal) {
            profile.reversalCount++;
            profile.lastReversal = block.timestamp;
        }
        
        // Successful transactions don't need special handling currently
        
        emit RiskFactorUpdated(wallet, calculateRiskFactor(wallet));
    }
    
    /**
     * @dev Flag a transaction as abnormal
     * @param wallet The wallet address
     */
    function flagAbnormalTransaction(address wallet) external onlyOwner {
        walletRiskProfiles[wallet].abnormalTxCount++;
        emit RiskFactorUpdated(wallet, calculateRiskFactor(wallet));
    }
    
    /**
     * @dev Get available credits for a wallet
     * @param wallet The wallet address
     * @return The available credit amount
     */
    function getAvailableCredits(address wallet) external view returns (uint256) {
        return incentiveCredits[wallet].amount;
    }
    
    /**
     * @dev Set the treasury address
     * @param _treasuryAddress The new treasury address
     */
    function setTreasuryAddress(address _treasuryAddress) external onlyOwner {
        require(_treasuryAddress != address(0), "Treasury address cannot be zero");
        treasuryAddress = _treasuryAddress;
    }
    
    /**
     * @dev Set the default HalfLife duration
     * @param _halfLifeDuration The new HalfLife duration in seconds
     */
    function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyOwner {
        require(_halfLifeDuration >= minHalfLifeDuration, "Below minimum HalfLife duration");
        require(_halfLifeDuration <= maxHalfLifeDuration, "Above maximum HalfLife duration");
        halfLifeDuration = _halfLifeDuration;
    }
    
    /**
     * @dev Set the minimum HalfLife duration
     * @param _minHalfLifeDuration The new minimum HalfLife duration in seconds
     */
    function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyOwner {
        require(_minHalfLifeDuration > 0, "Minimum HalfLife must be positive");
        require(_minHalfLifeDuration <= halfLifeDuration, "Minimum cannot exceed default");
        minHalfLifeDuration = _minHalfLifeDuration;
    }
    
    /**
     * @dev Set the maximum HalfLife duration
     * @param _maxHalfLifeDuration The new maximum HalfLife duration in seconds
     */
    function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyOwner {
        require(_maxHalfLifeDuration >= halfLifeDuration, "Maximum cannot be below default");
        maxHalfLifeDuration = _maxHalfLifeDuration;
    }
    
    /**
     * @dev Set the inactivity reset period
     * @param _inactivityResetPeriod The new inactivity reset period in seconds
     */
    function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyOwner {
        require(_inactivityResetPeriod > 0, "Inactivity period must be positive");
        inactivityResetPeriod = _inactivityResetPeriod;
    }
}
