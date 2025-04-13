// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
// import "hardhat/console.sol"; // Logging disabled

/**
 * @title T3Token (T3USD)
 * @dev ERC20 token with HalfLife, Reversals, Tiered Fees, Interbank Liability Tracking,
 * AccessControl, and Pausing capabilities.
 */
contract T3Token is ERC20, AccessControl, Pausable {

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
    uint256 private constant MIN_FEE_WEI = 1; // Note: 1 wei. Consider state variable if 1 token unit intended.
    uint256 private constant MAX_FEE_PERCENT = 500; // 5%

    // --- HalfLife Constants ---
    uint256 public halfLifeDuration = 3600;
    uint256 public minHalfLifeDuration = 600;
    uint256 public maxHalfLifeDuration = 86400;
    uint256 public inactivityResetPeriod = 30 days;

    // --- Addresses ---
    address public treasuryAddress;

    // --- Data Structures ---
    struct TransferMetadata { /* ... unchanged ... */ }
    struct RollingAverage { /* ... unchanged ... */ }
    struct WalletRiskProfile { /* ... unchanged ... */ }
    struct IncentiveCredits { /* ... unchanged ... */ }

    // --- Mappings ---
    mapping(address => TransferMetadata) public transferData;
    mapping(address => RollingAverage) public rollingAverages;
    mapping(address => mapping(address => uint256)) public transactionCountBetween;
    mapping(address => WalletRiskProfile) public walletRiskProfiles;
    mapping(address => IncentiveCredits) public incentiveCredits;

    // *** NEW: Tracking Issuance and Liabilities ***
    mapping(address => uint256) public mintedByMinter; // Tracks total amount minted by an address with MINTER_ROLE
    // Stores the amount that 'debtor' (issuer) owes 'creditor' (redeemer bank)
    mapping(address => mapping(address => uint256)) public interbankLiability;

    // --- Events ---
    event TransferWithFee(address indexed from, address indexed to, uint256 amount, uint256 fee);
    event TransferReversed(address indexed from, address indexed to, uint256 amount);
    event HalfLifeExpired(address indexed wallet, uint256 timestamp);
    event LoyaltyRefundProcessed(address indexed wallet, uint256 amount);
    event RiskFactorUpdated(address indexed wallet, uint256 newRiskFactor);
    event InterbankLiabilityRecorded(address indexed debtor, address indexed creditor, uint256 amount);
    event InterbankLiabilityCleared(address indexed debtor, address indexed creditor, uint256 amountCleared);
    event TokensMinted(address indexed minter, address indexed recipient, uint256 amount); // Added Mint event


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

        // Initialize admin's wallet risk profile
        walletRiskProfiles[initialAdmin].creationTime = block.timestamp;
    }

    // --- ERC20 Overrides and T3 Logic ---

    /**
     * @dev Override transfer function. Now includes Pausable modifier.
     */
    function transfer(address recipient, uint256 amount) public override whenNotPaused returns (bool) {
        // ... (rest of transfer logic unchanged, including updateWalletRiskProfile calls) ...
        require(recipient != address(0), "Transfer to zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        address sender = _msgSender();
        updateWalletRiskProfile(sender, false, false);
        updateWalletRiskProfile(recipient, false, false);
        if (transferData[sender].commitWindowEnd > block.timestamp && transferData[sender].originator != recipient) {
            revert("Cannot transfer during HalfLife period except back to originator");
        }
        uint256 feeBeforeAdjustments = calculateTieredFee(amount);
        uint256 feeAfterRisk = applyRiskAdjustments(feeBeforeAdjustments, sender, recipient);
        uint256 feeAfterCredits = applyCredits(sender, feeAfterRisk);
        uint256 finalFee = feeAfterCredits;
        uint256 maxFeeAmount = (amount * MAX_FEE_PERCENT) / BASIS_POINTS;
        if (finalFee > maxFeeAmount) { finalFee = maxFeeAmount; }
        uint256 minFeeCheck = MIN_FEE_WEI;
        if (finalFee < minFeeCheck && amount > minFeeCheck) { finalFee = minFeeCheck; }
        if (finalFee > amount) { finalFee = amount; }
        uint256 netAmount = amount - finalFee;
        _transfer(sender, recipient, netAmount); // Calls internal _update
        if (finalFee > 0) { processFee(sender, recipient, amount, finalFee); }
        transactionCountBetween[sender][recipient]++;
        uint256 adaptiveHalfLife = calculateAdaptiveHalfLife(sender, recipient, amount);
        transferData[recipient] = TransferMetadata({ commitWindowEnd: block.timestamp + adaptiveHalfLife, halfLifeDuration: adaptiveHalfLife, originator: sender, transferCount: transferData[recipient].transferCount + 1, reversalHash: keccak256(abi.encodePacked(sender, recipient, amount)), feeAmount: finalFee, isReversed: false });
        updateRollingAverage(recipient, amount);
        emit TransferWithFee(sender, recipient, netAmount, finalFee);
        return true;
    }

    /**
     * @dev Override required by AccessControl and Pausable.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, Pausable) {
        super._update(from, to, value);
    }


    // --- Core Logic Functions (Visibility adjusted) ---
    function calculateTieredFee(uint256 amount) internal view returns (uint256) { /* ... unchanged ... */ }
    function applyRiskAdjustments(uint256 baseFee, address sender, address recipient) internal view returns (uint256) { /* ... unchanged ... */ }
    function calculateRiskFactor(address wallet) public view returns (uint256) { /* ... unchanged ... */ } // Keep public for visibility?
    function applyCredits(address wallet, uint256 fee) internal returns (uint256) { /* ... unchanged ... */ }
    function processFee(address sender, address recipient, uint256 /*amount*/, uint256 feeAmount) internal { /* ... unchanged, includes recipientShare fix ... */ }
    function calculateAdaptiveHalfLife(address sender, address recipient, uint256 amount) internal view returns (uint256) { /* ... unchanged ... */ }
    function updateRollingAverage(address wallet, uint256 amount) internal { /* ... unchanged ... */ }
    function updateWalletRiskProfile(address wallet, bool isReversal, bool /*isSuccessfulCompletion*/) internal { /* ... unchanged ... */ }

    // --- Reversal & Expiry Functions ---
    function reverseTransfer(address from, address to, uint256 amount) external whenNotPaused { /* ... unchanged ... */ }
    function checkHalfLifeExpiry(address wallet) external whenNotPaused { /* ... unchanged ... */ }

    // --- View Functions ---
    function getAvailableCredits(address wallet) external view returns (uint256) { /* ... unchanged ... */ }

    // --- NEW: Minting and Burning Functions ---

    /**
     * @dev Mints tokens to a recipient address.
     * Requires MINTER_ROLE. Intended to be called based on verified off-chain fiat deposits.
     * Records the amount minted against the minter.
     * @param recipient The address to receive the minted tokens.
     * @param amount The amount of tokens to mint (in wei).
     */
    function mint(address recipient, uint256 amount) external whenNotPaused onlyRole(MINTER_ROLE) {
        // Note: Add allowance check here if using Stake-for-Allowance model later
        // require(amount <= minterAllowance[msg.sender], "Mint amount exceeds allowance");
        require(recipient != address(0), "Mint to the zero address");
        require(amount > 0, "Mint amount must be positive");

        address minter = _msgSender(); // The FI calling this function
        _mint(recipient, amount);
        mintedByMinter[minter] += amount;
        // minterAllowance[minter] -= amount; // Deduct from allowance if using that model

        emit TokensMinted(minter, recipient, amount);
    }

     /**
      * @dev Destroys `amount` tokens from the caller's account.
      * Standard burn function, callable by any token holder.
      * @param amount The amount of tokens to burn (in wei).
      */
     function burn(uint256 amount) external whenNotPaused {
         require(amount > 0, "Burn amount must be positive");
         _burn(_msgSender(), amount);
         // Note: Does NOT automatically adjust mintedByMinter or interbankLiability
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
         _burn(account, amount);
         // Note: Does NOT automatically adjust mintedByMinter or interbankLiability
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

    /**
     * @dev Sets the treasury address. Requires ADMIN_ROLE.
     */
    function setTreasuryAddress(address _treasuryAddress) external onlyRole(ADMIN_ROLE) {
        require(_treasuryAddress != address(0), "Treasury address cannot be zero");
        treasuryAddress = _treasuryAddress;
    }

    /**
     * @dev Sets the default HalfLife duration. Requires ADMIN_ROLE.
     */
    function setHalfLifeDuration(uint256 _halfLifeDuration) external onlyRole(ADMIN_ROLE) {
        require(_halfLifeDuration >= minHalfLifeDuration, "Below minimum");
        require(_halfLifeDuration <= maxHalfLifeDuration, "Above maximum");
        halfLifeDuration = _halfLifeDuration;
    }

    /**
     * @dev Sets the minimum HalfLife duration. Requires ADMIN_ROLE.
     */
    function setMinHalfLifeDuration(uint256 _minHalfLifeDuration) external onlyRole(ADMIN_ROLE) {
        require(_minHalfLifeDuration > 0, "Min must be positive");
        require(_minHalfLifeDuration <= halfLifeDuration, "Min exceeds default");
        minHalfLifeDuration = _minHalfLifeDuration;
    }

    /**
     * @dev Sets the maximum HalfLife duration. Requires ADMIN_ROLE.
     */
    function setMaxHalfLifeDuration(uint256 _maxHalfLifeDuration) external onlyRole(ADMIN_ROLE) {
        require(_maxHalfLifeDuration >= halfLifeDuration, "Max below default");
        maxHalfLifeDuration = _maxHalfLifeDuration;
    }

    /**
     * @dev Sets the inactivity reset period. Requires ADMIN_ROLE.
     */
    function setInactivityResetPeriod(uint256 _inactivityResetPeriod) external onlyRole(ADMIN_ROLE) {
        require(_inactivityResetPeriod > 0, "Period must be positive");
        inactivityResetPeriod = _inactivityResetPeriod;
    }

    // --- Pausing Functions ---
    /**
     * @dev Pauses the contract. Requires PAUSER_ROLE.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses the contract. Requires PAUSER_ROLE.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }


    // --- AccessControl Setup ---
    // SupportsInterface required for ERC165 + AccessControl
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC20, AccessControl) returns (bool) {
        return AccessControl.supportsInterface(interfaceId);
    }
}
