// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Using ERC20Pausable and AccessControl
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
// import "hardhat/console.sol"; // Logging disabled

/**
 * @title T3Token (T3USD)
 * @dev Pausable ERC20 token with HalfLife, Reversals, Tiered Fees, Interbank Liability Tracking,
 * AccessControl, and Pausing capabilities. Inherits ERC20Pausable for integrated pausing.
 */
// Inherit ERC20Pausable (includes ERC20 and Pausable) and AccessControl
contract T3Token is ERC20Pausable, AccessControl {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE"); // May or may not be needed depending on flow
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    // Add other roles as needed (e.g., CUSTODIAN_ROLE for registry)

    // --- Fee Structure Constants ---
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant TIER_MULTIPLIER = 10;
    uint256 private constant BASE_FEE_PERCENT = 1000 * BASIS_POINTS; // 1000%
    // *** UPDATED Fee Constants ***
    // Min fee requested: 0.00001% -> Interpreted as 0.00001 T3USD = 1 * 10**13 wei (assuming 18 decimals)
    uint256 private constant MIN_FEE_WEI = 10**13;
    // Max fee requested: 10% -> 1000 Basis Points
    uint256 private constant MAX_FEE_PERCENT = 1000;
    // *****************************

    // --- HalfLife Constants ---
    uint256 public halfLifeDuration = 3600;
    uint256 public minHalfLifeDuration = 600;
    uint256 public maxHalfLifeDuration = 86400;
    uint256 public inactivityResetPeriod = 30 days;

    // --- Addresses ---
    address public treasuryAddress;

    // --- Data Structures ---
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

    // --- Mappings ---
    mapping(address => TransferMetadata) public transferData;
    mapping(address => RollingAverage) public rollingAverages;
    mapping(address => mapping(address => uint256)) public transactionCountBetween;
    mapping(address => WalletRiskProfile) public walletRiskProfiles;
    mapping(address => IncentiveCredits) public incentiveCredits;
    // Added Minter/Liability tracking
    mapping(address => uint256) public mintedByMinter;
    mapping(address => mapping(address => uint256)) public interbankLiability;

    // --- Events ---
    event TransferWithFee(address indexed from, address indexed to, uint256 amount, uint256 fee);
    event TransferReversed(address indexed from, address indexed to, uint256 amount);
    event HalfLifeExpired(address indexed wallet, uint256 timestamp);
    event LoyaltyRefundProcessed(address indexed wallet, uint256 amount);
    event RiskFactorUpdated(address indexed wallet, uint256 newRiskFactor);
    // Added Interbank Liability and Mint events
    event InterbankLiabilityRecorded(address indexed debtor, address indexed creditor, uint256 amount);
    event InterbankLiabilityCleared(address indexed debtor, address indexed creditor, uint256 amountCleared);
    event TokensMinted(address indexed minter, address indexed recipient, uint256 amount);


    /**
     * @dev Constructor
     * Grants ADMIN_ROLE, PAUSER_ROLE and DEFAULT_ADMIN_ROLE to the deployer.
     */
    constructor(address initialAdmin, address _treasuryAddress) ERC20("T3 Stablecoin", "T3") {
        require(_treasuryAddress != address(0), "Treasury address cannot be zero");
        treasuryAddress = _treasuryAddress;

        // Grant necessary roles to the deployer/initial admin
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        // Mint initial supply to admin (or designated address)
        _mint(initialAdmin, 1000000 * 10**decimals());
        walletRiskProfiles[initialAdmin].creationTime = block.timestamp;
    }

    // --- ERC20 Overrides and T3 Logic ---

    /**
     * @dev Override transfer function. Includes profile init and T3 logic. Pausing handled by ERC20Pausable.
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        address sender = _msgSender();
        // Initialize profiles if needed BEFORE calculating risk
        updateWalletRiskProfile(sender, false, false);
        updateWalletRiskProfile(recipient, false, false);
        // Call internal function which includes T3 logic AND calls super._update (which has pause check)
        _transferWithT3Logic(sender, recipient, amount);
        return true;
    }

    /**
     * @dev Override transferFrom function. Pausing handled by ERC20Pausable.
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        // Initialize profiles if needed (optional here)
        // updateWalletRiskProfile(from, false, false);
        // updateWalletRiskProfile(to, false, false);
        // Call internal function which includes T3 logic AND calls super._update (which has pause check)
        _transferWithT3Logic(from, to, amount);
        return true;
    }

    /**
     * @dev Internal transfer function incorporating T3 logic before calling the pausable _update.
     */
    function _transferWithT3Logic(address sender, address recipient, uint256 amount) internal {
        require(recipient != address(0), "Transfer to zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        if (transferData[sender].commitWindowEnd > block.timestamp &&
            transferData[sender].originator != recipient) {
            revert("Cannot transfer during HalfLife period except back to originator");
        }

        // --- Fee Calculation Pipeline ---
        uint256 feeBeforeAdjustments = calculateTieredFee(amount);
        uint256 feeAfterRisk = applyRiskAdjustments(feeBeforeAdjustments, sender, recipient);
        uint256 feeAfterCredits = applyCredits(sender, feeAfterRisk);
        uint256 finalFee = feeAfterCredits;

        // Apply Max Bound (Now 10%)
        uint256 maxFeeAmount = (amount * MAX_FEE_PERCENT) / BASIS_POINTS; // MAX_FEE_PERCENT is now 1000
        if (finalFee > maxFeeAmount) { finalFee = maxFeeAmount; }

        // Apply Min Bound (Now 10**13 wei)
        uint256 minFeeCheck = MIN_FEE_WEI; // Use the updated constant
        if (finalFee < minFeeCheck && amount > minFeeCheck) { finalFee = minFeeCheck; }

        // Apply Amount Cap
        if (finalFee > amount) { finalFee = amount; }
        // --- End Fee Pipeline ---

        uint256 netAmount = amount - finalFee;

        // Calls the pausable _update from ERC20Pausable
        _update(sender, recipient, netAmount);

        // --- Post-transfer actions ---
        if (finalFee > 0) {
            processFee(sender, recipient, amount, finalFee);
        }
        transactionCountBetween[sender][recipient]++;
        uint256 adaptiveHalfLife = calculateAdaptiveHalfLife(sender, recipient, amount);
        transferData[recipient] = TransferMetadata({
            commitWindowEnd: block.timestamp + adaptiveHalfLife,
            halfLifeDuration: adaptiveHalfLife,
            originator: sender,
            transferCount: transferData[recipient].transferCount + 1,
            reversalHash: keccak256(abi.encodePacked(sender, recipient, amount)),
            feeAmount: finalFee,
            isReversed: false
        });
        updateRollingAverage(recipient, amount);
        emit TransferWithFee(sender, recipient, netAmount, finalFee);
    }

    // --- Core Logic Functions (Visibility adjusted) ---
    // Implementations are assumed to be the corrected versions from previous steps

    function calculateTieredFee(uint256 amount) internal view returns (uint256) {
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
    function applyRiskAdjustments(uint256 baseFee, address sender, address recipient) internal view returns (uint256) {
        uint256 senderRiskFactor = calculateRiskFactor(sender);
        uint256 recipientRiskFactor = calculateRiskFactor(recipient);
        uint256 riskFactor = senderRiskFactor > recipientRiskFactor ? senderRiskFactor : recipientRiskFactor;
        return (baseFee * riskFactor) / BASIS_POINTS;
     }
    function calculateRiskFactor(address wallet) public view returns (uint256) { // Kept public for easier testing/querying
        WalletRiskProfile storage profile = walletRiskProfiles[wallet];
        uint256 riskFactor = BASIS_POINTS;
        if (profile.creationTime > 0 && block.timestamp - profile.creationTime < 7 days) { riskFactor += 5000; }
        if (profile.lastReversal > 0 && block.timestamp - profile.lastReversal < 30 days) { riskFactor += 10000; }
        riskFactor += profile.reversalCount * 1000;
        riskFactor += profile.abnormalTxCount * 500;
        return riskFactor;
     }
    function applyCredits(address wallet, uint256 fee) internal returns (uint256) {
        IncentiveCredits storage credits = incentiveCredits[wallet];
        if (credits.amount == 0) { return fee; }
        if (credits.amount >= fee) {
            credits.amount -= fee;
            credits.lastUpdated = block.timestamp;
            return 0;
        } else {
            uint256 remainingFee = fee - credits.amount;
            credits.amount = 0;
            credits.lastUpdated = block.timestamp;
            return remainingFee;
        }
     }
    function processFee(address sender, address recipient, uint256 /*amount*/, uint256 feeAmount) internal {
        uint256 treasuryShare = feeAmount / 2;
        if (treasuryShare > 0) { _mint(treasuryAddress, treasuryShare); }
        uint256 senderShare = feeAmount / 4;
        incentiveCredits[sender].amount += senderShare;
        incentiveCredits[sender].lastUpdated = block.timestamp;
        uint256 recipientShare = feeAmount - treasuryShare - senderShare; // Corrected logic
        incentiveCredits[recipient].amount += recipientShare;
        incentiveCredits[recipient].lastUpdated = block.timestamp;
     }
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
                if (amount > avgAmount * 10) { duration = duration * 2; }
             }
        }
        if (duration < minHalfLifeDuration) { duration = minHalfLifeDuration; }
        else if (duration > maxHalfLifeDuration) { duration = maxHalfLifeDuration; }
        return duration;
     }
    function updateRollingAverage(address wallet, uint256 amount) internal {
         RollingAverage storage avg = rollingAverages[wallet];
        if (avg.lastUpdated > 0 && block.timestamp - avg.lastUpdated > inactivityResetPeriod) {
            avg.totalAmount = 0; avg.count = 0;
        }
        avg.totalAmount += amount; avg.count++; avg.lastUpdated = block.timestamp;
     }
    function updateWalletRiskProfile(address wallet, bool isReversal, bool /*isSuccessfulCompletion*/) internal {
        WalletRiskProfile storage profile = walletRiskProfiles[wallet];
        if (profile.creationTime == 0) {
            profile.creationTime = block.timestamp;
        }
        if (isReversal) {
            profile.reversalCount++;
            profile.lastReversal = block.timestamp;
        }
        emit RiskFactorUpdated(wallet, calculateRiskFactor(wallet));
     }

    // --- Reversal & Expiry Functions (Add whenNotPaused) ---
    function reverseTransfer(address from, address to, uint256 amount) external whenNotPaused {
        require(msg.sender == from , "Only receiver can initiate reversal");
        TransferMetadata storage meta = transferData[from];
        require(block.timestamp < meta.commitWindowEnd, "HalfLife expired");
        require(to == meta.originator, "Reversal must go back to originator");
        require(balanceOf(from) >= amount, "Insufficient balance to reverse");
        require(!meta.isReversed, "Transfer already reversed");
        meta.isReversed = true;
        updateWalletRiskProfile(from, true, false);
        updateWalletRiskProfile(to, true, false);
        _transfer(from, to, amount); // Calls internal _update hook
        delete transferData[from];
        emit TransferReversed(from, to, amount);
     }
    function checkHalfLifeExpiry(address wallet) external whenNotPaused {
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

    // --- View Functions ---
    function getAvailableCredits(address wallet) external view returns (uint256) { return incentiveCredits[wallet].amount; }

    // --- NEW: Minting and Burning Functions (Add whenNotPaused) ---
    /**
     * @dev Mints tokens to a recipient address.
     * Requires MINTER_ROLE. Intended to be called based on verified off-chain fiat deposits.
     * Records the amount minted against the minter.
     * @param recipient The address to receive the minted tokens.
     * @param amount The amount of tokens to mint (in wei).
     */
    function mint(address recipient, uint256 amount) external whenNotPaused onlyRole(MINTER_ROLE) {
        require(recipient != address(0), "Mint to the zero address");
        require(amount > 0, "Mint amount must be positive");
        address minter = _msgSender(); // The FI calling this function
        _mint(recipient, amount); // Calls internal _update hook
        mintedByMinter[minter] += amount;
        emit TokensMinted(minter, recipient, amount);
    }

     /**
      * @dev Destroys `amount` tokens from the caller's account.
      * Standard burn function, callable by any token holder.
      * @param amount The amount of tokens to burn (in wei).
      */
     function burn(uint256 amount) external whenNotPaused {
         require(amount > 0, "Burn amount must be positive");
         _burn(_msgSender(), amount); // Calls internal _update hook
     }

     /**
      * @dev Destroys `amount` tokens from `account`, reducing the caller's
      * allowance. Standard ERC20 burnFrom.
      * Requires allowance. Callable by anyone with sufficient allowance.
      * @param account The account whose tokens will be burnt.
      * @param amount The amount of tokens to burn (in wei).
      */
     function burnFrom(address account, uint256 amount) external whenNotPaused {
         require(amount > 0, "Burn amount must be positive");
         _spendAllowance(account, _msgSender(), amount);
         _burn(account, amount); // Calls internal _update hook
     }

    // --- NEW: Interbank Liability Functions ---
    /**
     * @dev Records a liability owed by a debtor bank to a creditor bank.
     * Requires ADMIN_ROLE.
     */
    function recordInterbankLiability(address debtor, address creditor, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(debtor != address(0), "Debtor cannot be zero address");
        require(creditor != address(0), "Creditor cannot be zero address");
        require(debtor != creditor, "Debtor cannot be creditor");
        require(amount > 0, "Amount must be positive");
        interbankLiability[debtor][creditor] += amount;
        emit InterbankLiabilityRecorded(debtor, creditor, amount);
     }
    /**
     * @dev Clears (reduces) a liability owed by a debtor bank to a creditor bank.
     * Requires ADMIN_ROLE.
     */
    function clearInterbankLiability(address debtor, address creditor, uint256 amountToClear) external onlyRole(ADMIN_ROLE) {
        require(debtor != address(0), "Debtor cannot be zero address");
        require(creditor != address(0), "Creditor cannot be zero address");
        require(debtor != creditor, "Debtor cannot be creditor");
        require(amountToClear > 0, "Amount to clear must be positive");
        uint256 currentLiability = interbankLiability[debtor][creditor];
        require(amountToClear <= currentLiability, "Amount to clear exceeds outstanding liability");
        interbankLiability[debtor][creditor] = currentLiability - amountToClear;
        emit InterbankLiabilityCleared(debtor, creditor, amountToClear);
     }

    // --- Admin / Role Management Functions (Using AccessControl) ---
    /**
     * @dev Flags a transaction associated with a wallet as abnormal.
     * Requires ADMIN_ROLE.
     */
    function flagAbnormalTransaction(address wallet) external onlyRole(ADMIN_ROLE) {
        updateWalletRiskProfile(wallet, false, false); // Ensure profile exists
        walletRiskProfiles[wallet].abnormalTxCount++;
        // Event emitted within updateWalletRiskProfile
     }
    /** @dev Sets the treasury address. Requires ADMIN_ROLE. */
    function setTreasuryAddress(address _treasuryAddress) external onlyRole(ADMIN_ROLE) { require(_treasuryAddress != address(0), "Treasury address cannot be zero"); treasuryAddress = _treasuryAddress; }
    /** @dev Sets the default HalfLife duration. Requires ADMIN_ROLE. */
    function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyRole(ADMIN_ROLE) { require(_halfLifeDuration >= minHalfLifeDuration, "Below minimum"); require(_halfLifeDuration <= maxHalfLifeDuration, "Above maximum"); halfLifeDuration = _halfLifeDuration; }
    /** @dev Sets the minimum HalfLife duration. Requires ADMIN_ROLE. */
    function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyRole(ADMIN_ROLE) { require(_minHalfLifeDuration > 0, "Min must be positive"); require(_minHalfLifeDuration <= halfLifeDuration, "Min exceeds default"); minHalfLifeDuration = _minHalfLifeDuration; }
    /** @dev Sets the maximum HalfLife duration. Requires ADMIN_ROLE. */
    function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyRole(ADMIN_ROLE) { require(_maxHalfLifeDuration >= halfLifeDuration, "Max below default"); maxHalfLifeDuration = _maxHalfLifeDuration; }
    /** @dev Sets the inactivity reset period. Requires ADMIN_ROLE. */
    function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyRole(ADMIN_ROLE) { require(_inactivityResetPeriod > 0, "Period must be positive"); inactivityResetPeriod = _inactivityResetPeriod; }

    // --- Pausing Functions ---
    /** @dev Pauses the contract. Requires PAUSER_ROLE. */
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    /** @dev Unpauses the contract. Requires PAUSER_ROLE. */
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // --- AccessControl Setup ---
    // NOTE: supportsInterface override removed to attempt compilation fix.
    // ERC165 compatibility might need further verification if this compiles.
    // function supportsInterface(bytes4 interfaceId) public view virtual override(ERC20Pausable, AccessControl) returns (bool) {
    //     return super.supportsInterface(interfaceId);
    // }

}
