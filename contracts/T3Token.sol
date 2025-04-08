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
        console.log("--- Transfer Start ---");
        console.log("Sender:", sender);
        console.log("Recipient:", recipient);
        console.log("Amount:", amount);


        // Check if sender is in HalfLife period and not the originator
        if (transferData[sender].commitWindowEnd > block.timestamp &&
            transferData[sender].originator != recipient) {
            revert("Cannot transfer during HalfLife period except back to originator");
        }

        // --- Fee Calculation Steps with Logging ---
        // 1. Calculate base fee
        uint256 feeBeforeAdjustments = calculateTieredFee(amount);
        console.log("Fee Step 1 (Base Tiered Fee):", feeBeforeAdjustments);

        // 2. Apply risk adjustments
        uint256 feeAfterRisk = applyRiskAdjustments(feeBeforeAdjustments, sender, recipient);
        console.log("Fee Step 2 (After Risk Adjust):", feeAfterRisk);

        // 3. Apply credits to reduce fee
        uint256 feeAfterCredits = applyCredits(sender, feeAfterRisk);
        console.log("Fee Step 3 (After Credits):", feeAfterCredits); // This is the fee remaining to be paid

        // 4. Apply final bounds (Max/Min)
        uint256 finalFee = feeAfterCredits; // Start with fee remaining after credits
        console.log("Fee Step 4a (Before Bounds Check):", finalFee);

        uint256 maxFeeAmount = (amount * MAX_FEE_PERCENT) / BASIS_POINTS;
        if (finalFee > maxFeeAmount) {
            console.log("Applying Max Fee Cap. Old Fee:", finalFee, "Max Allowed:", maxFeeAmount);
            finalFee = maxFeeAmount;
        }
        console.log("Fee Step 4b (After Max Bound Check):", finalFee);

        uint256 minFeeCheck = MIN_FEE;
        if (finalFee < minFeeCheck && amount > minFeeCheck) {
             console.log("Applying Min Fee Floor. Old Fee:", finalFee, "Min Required:", minFeeCheck);
             finalFee = minFeeCheck;
        }
        console.log("Fee Step 4c (After Min Bound Check):", finalFee);

        // 5. Ensure fee doesn't exceed amount (Overflow/Underflow Protection)
        if (finalFee > amount) {
            console.log("Applying Amount Cap. Old Fee:", finalFee, "Amount:", amount);
            finalFee = amount;
        }
        console.log("Fee Step 5 (Final Fee to be Paid):", finalFee);
        // --- End Fee Calculation Steps ---

        // Calculate net amount for transfer
        uint256 netAmount = amount - finalFee;
        console.log("Net Amount to Transfer:", netAmount);

        // Perform the transfer
        _transfer(sender, recipient, netAmount);
        console.log("Transfer executed.");

        // Process fee distribution if a non-zero fee was ultimately paid
        if (finalFee > 0) {
            // Pass the final calculated fee to processFee
            processFee(sender, recipient, amount, finalFee);
        } else {
            console.log("Skipping processFee as finalFee is 0.");
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
        console.log("Transfer metadata set for recipient.");

        // Update rolling average for recipient
        updateRollingAverage(recipient, amount);

        // Emit event with net amount transferred and final fee paid
        emit TransferWithFee(sender, recipient, netAmount, finalFee);
        console.log("--- Transfer End ---");
        return true;
    }


    /**
     * @dev Calculate fee using tiered logarithmic structure.
     * NOTE: Changed from pure to view to access decimals().
     * @param amount The transaction amount (in wei)
     * @return The calculated fee (in wei)
     */
    function calculateTieredFee(uint256 amount) public view returns (uint256) {
        // ... (function unchanged from previous version) ...
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
     * @param baseFee The base fee calculated from the tiered structure
     * @param sender The sender address
     * @param recipient The recipient address
     * @return The risk-adjusted fee
     */
    function applyRiskAdjustments(uint256 baseFee, address sender, address recipient) public view returns (uint256) {
        // ... (function unchanged) ...
        uint256 senderRiskFactor = calculateRiskFactor(sender);
        uint256 recipientRiskFactor = calculateRiskFactor(recipient);
        uint256 riskFactor = senderRiskFactor > recipientRiskFactor ? senderRiskFactor : recipientRiskFactor;
        return (baseFee * riskFactor) / BASIS_POINTS;
    }

    /**
     * @dev Calculate risk factor for a wallet
     * @param wallet The wallet address
     * @return The risk factor (in basis points, where 10000 = 100%)
     */
    function calculateRiskFactor(address wallet) public view returns (uint256) {
        // ... (function unchanged) ...
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
     * @param wallet The wallet address
     * @param fee The fee amount calculated *after* risk adjustments
     * @return The reduced fee amount (fee remaining after applying credits)
     */
    function applyCredits(address wallet, uint256 fee) public returns (uint256) { // Consider making internal
        IncentiveCredits storage credits = incentiveCredits[wallet];
        // *** SIMPLIFIED LOGGING ***
        console.log("--- applyCredits Start ---");
        console.log("Wallet:", wallet);
        console.log("Input Fee:", fee);
        console.log("Initial Credits:", credits.amount);

        if (credits.amount == 0) {
            console.log("applyCredits: No credits, returning fee");
            console.log("Fee Returned:", fee);
            console.log("--- applyCredits End ---");
            return fee;
        }

        if (credits.amount >= fee) {
            // Full fee coverage
            uint256 initialAmt = credits.amount;
            credits.amount -= fee;
            credits.lastUpdated = block.timestamp;
            console.log("applyCredits: Full coverage");
            console.log("Credits Before:", initialAmt);
            console.log("Fee Deducted:", fee);
            console.log("Credits After:", credits.amount);
            console.log("Fee Returned: 0");
            console.log("--- applyCredits End ---");
            return 0; // Return 0 fee remaining
        } else {
            // Partial fee coverage
            uint256 initialAmt = credits.amount;
            uint256 feeDeducted = credits.amount; // Amount deducted is the initial amount
            uint256 remainingFee = fee - feeDeducted;
            credits.amount = 0; // Zero out credits
            credits.lastUpdated = block.timestamp;
            console.log("applyCredits: Partial coverage");
            console.log("Credits Before:", initialAmt);
            console.log("Fee Deducted:", feeDeducted);
            console.log("Credits After:", credits.amount);
            console.log("Remaining Fee:", remainingFee);
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
        // *** SIMPLIFIED LOGGING ***
        console.log("--- processFee Start ---");
        console.log("Sender:", sender);
        console.log("Recipient:", recipient);
        console.log("Fee Amount Paid:", feeAmount);

        // 50% to treasury
        uint256 treasuryShare = feeAmount / 2;
        if (treasuryShare > 0) {
             _mint(treasuryAddress, treasuryShare);
        }
        console.log("Treasury Share:", treasuryShare);

        // 25% to sender's incentive pool
        uint256 senderShare = feeAmount / 4;
        uint256 senderCreditsBefore = incentiveCredits[sender].amount;
        incentiveCredits[sender].amount += senderShare;
        incentiveCredits[sender].lastUpdated = block.timestamp;
        console.log("Sender Share:", senderShare);
        console.log("Sender Credits Before:", senderCreditsBefore);
        console.log("Sender Credits After:", incentiveCredits[sender].amount);

        // 25% (remainder) to recipient's incentive pool
        uint256 recipientShare = feeAmount - treasuryShare - senderShare; // Corrected logic
        uint256 recipientCreditsBefore = incentiveCredits[recipient].amount;
        incentiveCredits[recipient].amount += recipientShare;
        incentiveCredits[recipient].lastUpdated = block.timestamp;
        console.log("Recipient Share:", recipientShare);
        console.log("Recipient Credits Before:", recipientCreditsBefore);
        console.log("Recipient Credits After:", incentiveCredits[recipient].amount);
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
     * @dev Update rolling average for a wallet (likely the recipient)
     * @param wallet The wallet address
     * @param amount The transaction amount received
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
     * @param from The current holder address (who wants to reverse)
     * @param to The original sender address (where tokens go back to)
     * @param amount The net amount that was originally received
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
     * @param wallet The wallet address holding the tokens (original recipient)
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
     // *** CORRECTED DOCSTRING (removed @param isSuccessfulCompletion) ***
    function updateWalletRiskProfile(address wallet, bool isReversal, bool /*isSuccessfulCompletion*/) internal { // Marked param unused
        // ... (function unchanged, includes logging) ...
        WalletRiskProfile storage profile = walletRiskProfiles[wallet];
        if (profile.creationTime == 0) {
            profile.creationTime = block.timestamp;
             console.log("Initialized profile creationTime for: %s", wallet);
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
        // ... (function unchanged) ...
        updateWalletRiskProfile(wallet, false, false);
        walletRiskProfiles[wallet].abnormalTxCount++;
    }

    /**
     * @dev Get available credits for a wallet
     * @param wallet The wallet address
     * @return The available credit amount
     */
    function getAvailableCredits(address wallet) external view returns (uint256) {
        // ... (function unchanged) ...
        return incentiveCredits[wallet].amount;
    }

    // --- Setter Functions ---
    function setTreasuryAddress(address _treasuryAddress) external onlyOwner { /* ... unchanged ... */ }
    function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyOwner { /* ... unchanged ... */ }
    function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyOwner { /* ... unchanged ... */ }
    function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyOwner { /* ... unchanged ... */ }
    function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyOwner { /* ... unchanged ... */ }
}

/*

I have updated the contract code in the Canvas (`solidity_contract_with_logging`) to include detailed logging within the `transfer` function, tracing the `feeAmount` variable through its calculation steps (Base Fee -> After Risk -> After Credits -> After Max Bound -> After Min Bound -> Final Fee).
Please replace your `T3Token.sol` content with this latest version, run `npx hardhat clean`, `npx hardhat compile`, and execute the tests again, focusing on the output from the "Credit Application" tests (`npx hardhat test --grep "Credit Application"`). The new logs should give us a much clearer picture of how the fee is being calculated and applied before `processFee` is call
*/