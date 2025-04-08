// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol"; // Make sure this import is at the top

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
        // Note: Other profiles are initialized via updateWalletRiskProfile calls
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

        // Check if sender is in HalfLife period and not the originator
        if (transferData[sender].commitWindowEnd > block.timestamp &&
            transferData[sender].originator != recipient) {
            revert("Cannot transfer during HalfLife period except back to originator");
        }

        // Calculate base fee using tiered logarithmic structure
        uint256 feeBeforeAdjustments = calculateTieredFee(amount);

        // Apply risk adjustments
        uint256 feeAfterRisk = applyRiskAdjustments(feeBeforeAdjustments, sender, recipient);

        // Apply credits to reduce fee - This returns the fee *remaining* after credits
        uint256 feeAfterCredits = applyCredits(sender, feeAfterRisk);

        // Apply final bounds (Max/Min) to the fee remaining after credits
        uint256 finalFee = feeAfterCredits;
        uint256 maxFeeAmount = (amount * MAX_FEE_PERCENT) / BASIS_POINTS;
        if (finalFee > maxFeeAmount) {
            finalFee = maxFeeAmount;
        }

        // Check MIN_FEE constant interpretation (currently 1 wei)
        uint256 minFeeCheck = MIN_FEE; // Use constant directly
        // If MIN_FEE was intended as 1 token unit, use a state variable instead:
        // uint256 minFeeCheck = minFeeAmount;
        if (finalFee < minFeeCheck && amount > minFeeCheck) {
             finalFee = minFeeCheck;
        }

        // Ensure fee doesn't exceed amount (prevents underflow)
        // It's possible credits reduce fee significantly, then min_fee brings it back up.
        if (finalFee > amount) {
            finalFee = amount; // Cap fee at the transfer amount itself
        }

        // Calculate net amount for transfer
        uint256 netAmount = amount - finalFee;

        // Perform the transfer
        _transfer(sender, recipient, netAmount);

        // Process fee distribution if a non-zero fee was ultimately paid
        if (finalFee > 0) {
            // Pass the final calculated fee to processFee
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
            transferCount: transferData[recipient].transferCount + 1, // Note: Reads recipient's old count
            reversalHash: keccak256(abi.encodePacked(sender, recipient, amount)),
            feeAmount: finalFee, // Store the final fee paid
            isReversed: false
        });

        // Update rolling average for recipient (should this be netAmount?)
        updateRollingAverage(recipient, amount); // Currently uses gross amount

        // Emit event with net amount transferred and final fee paid
        emit TransferWithFee(sender, recipient, netAmount, finalFee);
        return true;
    }


    /**
     * @dev Calculate fee using tiered logarithmic structure.
     * NOTE: Changed from pure to view to access decimals().
     * @param amount The transaction amount (in wei)
     * @return The calculated fee (in wei)
     */
    function calculateTieredFee(uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;

        uint256 _decimals = decimals(); // Get token decimals

        uint256 remainingAmount = amount;
        uint256 totalFee = 0;

        // Initialize tier ceiling based on 1 full token unit
        uint256 tierCeiling = 1 * (10**_decimals); // e.g., 1 * 10**18

        uint256 tierFloor = 0;
        uint256 currentFeePercent = BASE_FEE_PERCENT; // 10,000,000 BP (1000%)

        while (remainingAmount > 0) {
            uint256 amountInTier;
            uint256 tierSize = tierCeiling - tierFloor;

            if (tierCeiling < tierFloor) break; // Safety check
            if (tierSize == 0) break; // Avoid issues if multiplier is 1 or ceiling doesn't grow

            if (remainingAmount > tierSize) {
                amountInTier = tierSize;
                remainingAmount -= amountInTier;
            } else {
                amountInTier = remainingAmount;
                remainingAmount = 0;
            }

            uint256 tierFee = (amountInTier * currentFeePercent) / BASIS_POINTS;
            totalFee += tierFee;

            tierFloor = tierCeiling;
             // Check for potential overflow before multiplying ceiling
             uint256 nextTierCeiling = tierCeiling * TIER_MULTIPLIER;
             // Check overflow using safe multiplication pattern
             if (TIER_MULTIPLIER != 0 && nextTierCeiling / TIER_MULTIPLIER != tierCeiling && tierCeiling > 0) {
                 // Overflow occurred, apply last fee % to remainder and break
                 if (remainingAmount > 0) {
                    tierFee = (remainingAmount * currentFeePercent) / BASIS_POINTS;
                    totalFee += tierFee;
                    remainingAmount = 0;
                 }
                 break;
             }
             tierCeiling = nextTierCeiling;

            // Decrease fee percentage for the next tier
            currentFeePercent = currentFeePercent / TIER_MULTIPLIER;

            if (currentFeePercent == 0) {
                 // If fee % is 0, no more fees apply to remaining amount
                 break;
             }
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
        // Requires profile.creationTime to be set (e.g., via updateWalletRiskProfile)
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
     * @param fee The fee amount calculated *after* risk adjustments
     * @return The reduced fee amount (fee remaining after applying credits)
     */
    function applyCredits(address wallet, uint256 fee) public returns (uint256) { // Consider making internal
        IncentiveCredits storage credits = incentiveCredits[wallet];
        // *** UPDATED LOGGING ***
        console.log("--- applyCredits Start ---");
        console.log("Wallet: %s", wallet);
        console.log("Input Fee: %s", fee);
        console.log("Initial Credits: %s", credits.amount);

        if (credits.amount == 0) {
            console.log("applyCredits: No credits, returning fee %s", fee);
            console.log("--- applyCredits End ---");
            return fee;
        }

        if (credits.amount >= fee) {
            // Full fee coverage
            uint256 initialAmt = credits.amount; // Temp var for logging
            credits.amount -= fee;
            credits.lastUpdated = block.timestamp;
            console.log("applyCredits: Full coverage. Credits Before=%s, Fee Deducted=%s, Credits After=%s", initialAmt, fee, credits.amount);
            console.log("--- applyCredits End ---");
            return 0; // Return 0 fee remaining
        } else {
            // Partial fee coverage
            uint256 initialAmt = credits.amount; // Temp var for logging
            uint256 remainingFee = fee - credits.amount;
            credits.amount = 0; // Zero out credits
            credits.lastUpdated = block.timestamp;
            console.log("applyCredits: Partial coverage. Credits Before=%s, Fee Deducted=%s, Credits After=%s, Remaining Fee=%s", initialAmt, initialAmt, credits.amount, remainingFee);
            console.log("--- applyCredits End ---");
            return remainingFee; // Return the fee that still needs to be paid
        }
    }

    /**
     * @dev Process fee distribution between treasury and incentive pools
     * @param sender The sender address
     * @param recipient The recipient address
     * @param feeAmount The final fee amount actually paid (after credits, bounds)
     */
     // *** CORRECTED DOCSTRING (removed @param amount) ***
    function processFee(address sender, address recipient, uint256 /*amount*/, uint256 feeAmount) internal {
        // *** UPDATED LOGGING ***
        console.log("--- processFee Start ---");
        console.log("Sender: %s", sender);
        console.log("Recipient: %s", recipient);
        console.log("Fee Amount Paid: %s", feeAmount);

        // 50% to treasury
        uint256 treasuryShare = feeAmount / 2;
        if (treasuryShare > 0) {
             _mint(treasuryAddress, treasuryShare);
        }
        console.log("Treasury Share: %s", treasuryShare);

        // 25% to sender's incentive pool
        uint256 senderShare = feeAmount / 4;
        uint256 senderCreditsBefore = incentiveCredits[sender].amount;
        incentiveCredits[sender].amount += senderShare;
        incentiveCredits[sender].lastUpdated = block.timestamp;
        console.log("Sender Share: %s", senderShare);
        console.log("Sender Credits Before: %s", senderCreditsBefore);
        console.log("Sender Credits After: %s", incentiveCredits[sender].amount);

        // 25% (remainder) to recipient's incentive pool
        uint256 recipientShare = feeAmount - treasuryShare - senderShare; // Corrected logic
        uint256 recipientCreditsBefore = incentiveCredits[recipient].amount;
        incentiveCredits[recipient].amount += recipientShare;
        incentiveCredits[recipient].lastUpdated = block.timestamp;
        console.log("Recipient Share: %s", recipientShare);
        console.log("Recipient Credits Before: %s", recipientCreditsBefore);
        console.log("Recipient Credits After: %s", incentiveCredits[recipient].amount);
        console.log("--- processFee End ---");
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
        uint256 txCount = transactionCountBetween[sender][recipient];
        if (txCount > 0) {
            uint256 reduction = (txCount * 10 > 90) ? 90 : txCount * 10;
            duration = duration * (100 - reduction) / 100;
        }
        RollingAverage storage avg = rollingAverages[sender];
        if (avg.count > 0) {
             if (avg.totalAmount > 0) {
                uint256 avgAmount = avg.totalAmount / avg.count;
                if (amount > avgAmount * 10) {
                    duration = duration * 2;
                }
             }
        }
        if (duration < minHalfLifeDuration) { duration = minHalfLifeDuration; }
        else if (duration > maxHalfLifeDuration) { duration = maxHalfLifeDuration; }
        return duration;
    }

    /**
     * @dev Update rolling average for a wallet (likely the recipient)
     * @param wallet The wallet address
     * @param amount The transaction amount received
     */
    function updateRollingAverage(address wallet, uint256 amount) internal {
        RollingAverage storage avg = rollingAverages[wallet];
        if (avg.lastUpdated > 0 && block.timestamp - avg.lastUpdated > inactivityResetPeriod) {
            avg.totalAmount = 0; avg.count = 0;
        }
        avg.totalAmount += amount; avg.count++; avg.lastUpdated = block.timestamp;
    }

    /**
     * @dev Reverse a transfer within the HalfLife period
     * @param from The current holder address (who wants to reverse)
     * @param to The original sender address (where tokens go back to)
     * @param amount The net amount that was originally received
     */
    function reverseTransfer(address from, address to, uint256 amount) external {
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
     * @param wallet The wallet address holding the tokens (original recipient)
     */
    function checkHalfLifeExpiry(address wallet) external {
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
     * @param isSuccessfulCompletion Whether this update is due to successful HalfLife expiry
     */
    function updateWalletRiskProfile(address wallet, bool isReversal, bool /*isSuccessfulCompletion*/) internal { // Marked param unused
        WalletRiskProfile storage profile = walletRiskProfiles[wallet];
        if (profile.creationTime == 0) {
            profile.creationTime = block.timestamp;
             console.log("Initialized profile creationTime for: %s", wallet); // Use format specifier
        }
        if (isReversal) {
            profile.reversalCount++;
            profile.lastReversal = block.timestamp;
        }
        emit RiskFactorUpdated(wallet, calculateRiskFactor(wallet));
    }

    /**
     * @dev Flag a transaction as abnormal (callable by owner)
     * @param wallet The wallet address associated with the abnormal transaction
     */
    function flagAbnormalTransaction(address wallet) external onlyOwner {
        updateWalletRiskProfile(wallet, false, false); // Ensure profile exists
        walletRiskProfiles[wallet].abnormalTxCount++;
        // Event emitted within updateWalletRiskProfile
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
     * @dev Set the treasury address (callable by owner)
     * @param _treasuryAddress The new treasury address
     */
    function setTreasuryAddress(address _treasuryAddress) external onlyOwner {
        require(_treasuryAddress != address(0), "Treasury address cannot be zero");
        treasuryAddress = _treasuryAddress;
    }

    /**
     * @dev Set the default HalfLife duration (callable by owner)
     * @param _halfLifeDuration The new HalfLife duration in seconds
     */
    function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyOwner {
        require(_halfLifeDuration >= minHalfLifeDuration, "Below minimum HalfLife duration");
        require(_halfLifeDuration <= maxHalfLifeDuration, "Above maximum HalfLife duration");
        halfLifeDuration = _halfLifeDuration;
    }

    /**
     * @dev Set the minimum HalfLife duration (callable by owner)
     * @param _minHalfLifeDuration The new minimum HalfLife duration in seconds
     */
    function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyOwner {
        require(_minHalfLifeDuration > 0, "Minimum HalfLife must be positive");
        require(_minHalfLifeDuration <= halfLifeDuration, "Minimum cannot exceed default");
        minHalfLifeDuration = _minHalfLifeDuration;
    }

    /**
     * @dev Set the maximum HalfLife duration (callable by owner)
     * @param _maxHalfLifeDuration The new maximum HalfLife duration in seconds
     */
    function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyOwner {
        require(_maxHalfLifeDuration >= halfLifeDuration, "Maximum cannot be below default");
        maxHalfLifeDuration = _maxHalfLifeDuration;
    }

    /**
     * @dev Set the inactivity reset period (callable by owner)
     * @param _inactivityResetPeriod The new inactivity reset period in seconds
     */
    function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyOwner {
        require(_inactivityResetPeriod > 0, "Inactivity period must be positive");
        inactivityResetPeriod = _inactivityResetPeriod;
    }
}
/*
I have updated the code in the Canvas:
* Removed the `@param amount` line from the `processFee` docstring.
* Rewrote the `console.log` calls in `applyCredits` and `processFee` to use simpler arguments or format specifiers (`%s`) which are generally better supported by Hardhat's console.

Please replace the code in your `T3Token.sol` file with the updated version from the Canvas, then run `npx hardhat clean`, `npx hardhat compile`, and execute the tests again (`npx hardhat test --grep "Credit Application"`). Let me know the log outp
*/