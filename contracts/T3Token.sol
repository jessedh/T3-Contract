// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
// import "hardhat/console.sol"; // Logging disabled

/**
 * @title T3Token
 * @dev ERC20 token with HalfLife mechanism, transfer reversal capabilities, and tiered logarithmic fee structure
 */
contract T3Token is ERC20, Ownable {
    // Fee structure constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant TIER_MULTIPLIER = 10;
    uint256 private constant BASE_FEE_PERCENT = 1000 * BASIS_POINTS; // 1000% for first tier
    // NOTE: MIN_FEE = 1 means 1 wei. If intended as 1 token unit, consider changing to a state variable set in constructor.
    uint256 private constant MIN_FEE = 1;
    uint256 private constant MAX_FEE_PERCENT = 500; // 5% fee cap (500 basis points)

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
        uint256 feeAmount; // Fee paid *after* credits/bounds
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
     * @param amount The amount to transfer (in wei)
     * @return bool Success indicator
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        require(recipient != address(0), "Transfer to zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        address sender = _msgSender();

        // *** ADDED: Initialize profiles if needed BEFORE calculating risk ***
        // This ensures creationTime is set on first interaction, affecting risk calc immediately.
        updateWalletRiskProfile(sender, false, false);
        updateWalletRiskProfile(recipient, false, false);
        // ********************************************************************

        // Check if sender is in HalfLife period and not the originator
        if (transferData[sender].commitWindowEnd > block.timestamp &&
            transferData[sender].originator != recipient) {
            revert("Cannot transfer during HalfLife period except back to originator");
        }

        // --- Fee Calculation Steps ---
        // 1. Calculate base fee
        uint256 feeBeforeAdjustments = calculateTieredFee(amount);

        // 2. Apply risk adjustments (now uses potentially initialized profiles)
        uint256 feeAfterRisk = applyRiskAdjustments(feeBeforeAdjustments, sender, recipient);

        // 3. Apply credits to reduce fee
        uint256 feeAfterCredits = applyCredits(sender, feeAfterRisk);

        // 4. Apply final bounds (Max/Min)
        uint256 finalFee = feeAfterCredits;
        uint256 maxFeeAmount = (amount * MAX_FEE_PERCENT) / BASIS_POINTS;
        if (finalFee > maxFeeAmount) {
            finalFee = maxFeeAmount;
        }
        uint256 minFeeCheck = MIN_FEE;
        if (finalFee < minFeeCheck && amount > minFeeCheck) {
             finalFee = minFeeCheck;
        }

        // 5. Ensure fee doesn't exceed amount (Overflow/Underflow Protection)
        if (finalFee > amount) {
            finalFee = amount;
        }
        // --- End Fee Calculation Steps ---

        // Calculate net amount for transfer
        uint256 netAmount = amount - finalFee;

        // Perform the transfer
        _transfer(sender, recipient, netAmount);

        // Process fee distribution if a non-zero fee was ultimately paid
        if (finalFee > 0) {
            processFee(sender, recipient, amount, finalFee);
        }

        // Update transaction count between sender and recipient
        transactionCountBetween[sender][recipient]++;

        // Calculate adaptive HalfLife duration
        uint256 adaptiveHalfLife = calculateAdaptiveHalfLife(sender, recipient, amount);

        // Set transfer metadata for the recipient
        transferData[recipient] = TransferMetadata({
            commitWindowEnd: block.timestamp + adaptiveHalfLife,
            halfLifeDuration: adaptiveHalfLife,
            originator: sender,
            transferCount: transferData[recipient].transferCount + 1,
            reversalHash: keccak256(abi.encodePacked(sender, recipient, amount)),
            feeAmount: finalFee, // Store the final fee paid
            isReversed: false
        });

        // Update rolling average for recipient
        updateRollingAverage(recipient, amount);

        // Emit event with net amount transferred and final fee paid
        emit TransferWithFee(sender, recipient, netAmount, finalFee);
        return true;
    }


    /**
     * @dev Calculate fee using tiered logarithmic structure.
     */
    function calculateTieredFee(uint256 amount) public view returns (uint256) {
        // ... (function unchanged - no logging) ...
        if (amount == 0) return 0;
        uint256 _decimals = decimals();
        uint256 remainingAmount = amount;
        uint256 totalFee = 0;
        uint256 tierCeiling = 1 * (10**_decimals);
        uint256 tierFloor = 0;
        uint256 currentFeePercent = BASE_FEE_PERCENT;
        while (remainingAmount > 0) {
            uint256 amountInTier;
            uint256 tierSize = tierCeiling - tierFloor;
            if (tierCeiling < tierFloor) break;
            if (tierSize == 0) break;
            if (remainingAmount > tierSize) {
                amountInTier = tierSize; remainingAmount -= amountInTier;
            } else {
                amountInTier = remainingAmount; remainingAmount = 0;
            }
            uint256 tierFee = (amountInTier * currentFeePercent) / BASIS_POINTS;
            totalFee += tierFee;
            tierFloor = tierCeiling;
             uint256 nextTierCeiling = tierCeiling * TIER_MULTIPLIER;
             if (TIER_MULTIPLIER != 0 && nextTierCeiling / TIER_MULTIPLIER != tierCeiling && tierCeiling > 0) {
                 if (remainingAmount > 0) {
                    tierFee = (remainingAmount * currentFeePercent) / BASIS_POINTS;
                    totalFee += tierFee; remainingAmount = 0;
                 }
                 break;
             }
             tierCeiling = nextTierCeiling;
            currentFeePercent = currentFeePercent / TIER_MULTIPLIER;
            if (currentFeePercent == 0) { break; }
        }
        return totalFee;
    }

    /**
     * @dev Apply risk adjustments to the base fee
     */
    function applyRiskAdjustments(uint256 baseFee, address sender, address recipient) public view returns (uint256) {
        // ... (function unchanged - no logging) ...
        uint256 senderRiskFactor = calculateRiskFactor(sender);
        uint256 recipientRiskFactor = calculateRiskFactor(recipient);
        uint256 riskFactor = senderRiskFactor > recipientRiskFactor ? senderRiskFactor : recipientRiskFactor;
        return (baseFee * riskFactor) / BASIS_POINTS;
    }

    /**
     * @dev Calculate risk factor for a wallet
     */
    function calculateRiskFactor(address wallet) public view returns (uint256) {
        // ... (function unchanged - no logging) ...
        WalletRiskProfile storage profile = walletRiskProfiles[wallet];
        uint256 riskFactor = BASIS_POINTS;
        if (profile.creationTime > 0 && block.timestamp - profile.creationTime < 7 days) { riskFactor += 5000; }
        if (profile.lastReversal > 0 && block.timestamp - profile.lastReversal < 30 days) { riskFactor += 10000; }
        riskFactor += profile.reversalCount * 1000;
        riskFactor += profile.abnormalTxCount * 500;
        return riskFactor;
    }

    /**
     * @dev Apply available credits to reduce fee
     */
    function applyCredits(address wallet, uint256 fee) public returns (uint256) { // Consider making internal
        // ... (function unchanged - no logging) ...
        IncentiveCredits storage credits = incentiveCredits[wallet];
        if (credits.amount == 0) { return fee; }
        if (credits.amount >= fee) {
            credits.amount -= fee;
            credits.lastUpdated = block.timestamp;
            return 0;
        } else {
            uint256 remainingFee = fee - credits.amount;
            credits.amount = 0; // Zero out credits
            credits.lastUpdated = block.timestamp;
            return remainingFee;
        }
    }

    /**
     * @dev Process fee distribution between treasury and incentive pools
     */
    function processFee(address sender, address recipient, uint256 /*amount*/, uint256 feeAmount) internal {
        // ... (function unchanged - no logging) ...
        uint256 treasuryShare = feeAmount / 2;
        if (treasuryShare > 0) { _mint(treasuryAddress, treasuryShare); }
        uint256 senderShare = feeAmount / 4;
        incentiveCredits[sender].amount += senderShare;
        incentiveCredits[sender].lastUpdated = block.timestamp;
        uint256 recipientShare = feeAmount - treasuryShare - senderShare; // Corrected logic
        incentiveCredits[recipient].amount += recipientShare;
        incentiveCredits[recipient].lastUpdated = block.timestamp;
    }

    /**
     * @dev Calculate adaptive HalfLife duration based on transaction patterns
     */
    function calculateAdaptiveHalfLife(address sender, address recipient, uint256 amount) internal view returns (uint256) {
        // ... (function unchanged) ...
        uint256 duration = halfLifeDuration;
        uint256 txCount = transactionCountBetween[sender][recipient];
        if (txCount > 0) {
            uint256 reduction = (txCount * 10 > 90) ? 90 : txCount * 10;
            duration = duration * (100 - reduction) / 100;
        }
        RollingAverage storage avg = rollingAverages[sender];
        if (avg.count > 0) {
             if (avg.totalAmount > 0) {
                uint256 avgAmount = avg.totalAmount / avg.count;
                if (amount > avgAmount * 10) { duration = duration * 2; }
             }
        }
        if (duration < minHalfLifeDuration) { duration = minHalfLifeDuration; }
        else if (duration > maxHalfLifeDuration) { duration = maxHalfLifeDuration; }
        return duration;
    }

    /**
     * @dev Update rolling average for a wallet
     */
    function updateRollingAverage(address wallet, uint256 amount) internal {
        // ... (function unchanged) ...
         RollingAverage storage avg = rollingAverages[wallet];
        if (avg.lastUpdated > 0 && block.timestamp - avg.lastUpdated > inactivityResetPeriod) {
            avg.totalAmount = 0; avg.count = 0;
        }
        avg.totalAmount += amount; avg.count++; avg.lastUpdated = block.timestamp;
    }

    /**
     * @dev Reverse a transfer within the HalfLife period
     */
    function reverseTransfer(address from, address to, uint256 amount) external {
        // ... (function unchanged) ...
        require(msg.sender == from , "Only receiver can initiate reversal");
        TransferMetadata storage meta = transferData[from];
        require(block.timestamp < meta.commitWindowEnd, "HalfLife expired");
        require(to == meta.originator, "Reversal must go back to originator");
        require(balanceOf(from) >= amount, "Insufficient balance to reverse");
        require(!meta.isReversed, "Transfer already reversed");
        meta.isReversed = true;
        updateWalletRiskProfile(from, true, false);
        updateWalletRiskProfile(to, true, false);
        _transfer(from, to, amount);
        delete transferData[from];
        emit TransferReversed(from, to, amount);
    }

    /**
     * @dev Check if HalfLife period has expired and process loyalty refunds
     */
    function checkHalfLifeExpiry(address wallet) external {
        // ... (function unchanged) ...
        TransferMetadata storage meta = transferData[wallet];
        require(meta.commitWindowEnd > 0, "No active transfer data");
        require(block.timestamp >= meta.commitWindowEnd, "HalfLife not expired yet");
        require(!meta.isReversed, "Transfer was reversed");
        uint256 feePaid = meta.feeAmount;
        if (feePaid > 0) {
            uint256 refundAmount = feePaid / 8;
            if (refundAmount > 0) {
                incentiveCredits[meta.originator].amount += refundAmount;
                incentiveCredits[meta.originator].lastUpdated = block.timestamp;
                incentiveCredits[wallet].amount += refundAmount;
                incentiveCredits[wallet].lastUpdated = block.timestamp;
                emit LoyaltyRefundProcessed(meta.originator, refundAmount);
                emit LoyaltyRefundProcessed(wallet, refundAmount);
            }
        }
        updateWalletRiskProfile(wallet, false, true);
        updateWalletRiskProfile(meta.originator, false, true);
        delete transferData[wallet];
        emit HalfLifeExpired(wallet, block.timestamp);
    }

    /**
     * @dev Update wallet risk profile. Initializes creationTime if needed.
     * @param wallet The wallet address
     * @param isReversal Whether this update is due to a reversal event
     */
    function updateWalletRiskProfile(address wallet, bool isReversal, bool /*isSuccessfulCompletion*/) internal {
        // *** Logging Commented Out ***
        WalletRiskProfile storage profile = walletRiskProfiles[wallet];
        // console.log("--- updateWalletRiskProfile ---");
        // console.log("Wallet:", wallet);
        // console.log("Initial creationTime:", profile.creationTime);

        if (profile.creationTime == 0) {
            profile.creationTime = block.timestamp;
             // console.log("Initialized profile creationTime for %s to %s", wallet, profile.creationTime);
        }
        if (isReversal) {
            profile.reversalCount++;
            profile.lastReversal = block.timestamp;
             // console.log("Updated reversal info for %s", wallet);
        }
        emit RiskFactorUpdated(wallet, calculateRiskFactor(wallet));
        // console.log("--- updateWalletRiskProfile End ---");
    }

    /**
     * @dev Flag a transaction as abnormal (callable by owner)
     */
    function flagAbnormalTransaction(address wallet) external onlyOwner {
        // Call updateWalletRiskProfile first to ensure profile exists
        updateWalletRiskProfile(wallet, false, false);
        walletRiskProfiles[wallet].abnormalTxCount++;
        // Event emitted within updateWalletRiskProfile
        // console.log("Flagged abnormal tx for %s", wallet);
    }

    /**
     * @dev Get available credits for a wallet
     */
    function getAvailableCredits(address wallet) external view returns (uint256) {
        return incentiveCredits[wallet].amount;
    }

    // --- Setter Functions ---
    function setTreasuryAddress(address _treasuryAddress) external onlyOwner { require(_treasuryAddress != address(0), "Treasury address cannot be zero"); treasuryAddress = _treasuryAddress; }
    function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyOwner { require(_halfLifeDuration >= minHalfLifeDuration, "Below minimum"); require(_halfLifeDuration <= maxHalfLifeDuration, "Above maximum"); halfLifeDuration = _halfLifeDuration; }
    function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyOwner { require(_minHalfLifeDuration > 0, "Min must be positive"); require(_minHalfLifeDuration <= halfLifeDuration, "Min exceeds default"); minHalfLifeDuration = _minHalfLifeDuration; }
    function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyOwner { require(_maxHalfLifeDuration >= halfLifeDuration, "Max below default"); maxHalfLifeDuration = _maxHalfLifeDuration; }
    function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyOwner { require(_inactivityResetPeriod > 0, "Period must be positive"); inactivityResetPeriod = _inactivityResetPeriod; }
}