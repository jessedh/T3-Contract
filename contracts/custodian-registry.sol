// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol"; // Optional: for tracking custodians

/**
 * @title Custodian Registry
 * @dev Manages the registration of user wallets custodied by authorized Financial Institutions (FIs).
 * Stores KYC status timestamps associated with registered wallets.
 * Uses AccessControl:
 * - ADMIN_ROLE: Can grant/revoke CUSTODIAN_ROLE to FIs.
 * - CUSTODIAN_ROLE: Granted to FIs, allows them to register/update wallets they custody.
 */
contract CustodianRegistry is AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");

    // --- Data Structures ---
    struct CustodyData {
        address custodian; // Address of the FI acting as custodian
        uint256 kycValidatedTimestamp; // Timestamp when KYC was last validated by custodian
        uint256 kycExpiresTimestamp;   // Timestamp when KYC validation expires (0 if never expires)
    }

    // --- State Variables ---
    // Mapping from user address to their custody data
    mapping(address => CustodyData) private _custodyInfo;

    // Optional: Keep track of all registered custodians for transparency
    EnumerableSet.AddressSet private _custodians;

    // --- Events ---
    event WalletRegistered(address indexed userAddress, address indexed custodian, uint256 kycValidatedTimestamp, uint256 kycExpiresTimestamp);
    event WalletUnregistered(address indexed userAddress, address indexed custodian);
    event KYCStatusUpdated(address indexed userAddress, address indexed custodian, uint256 kycValidatedTimestamp, uint256 kycExpiresTimestamp);

    /**
     * @dev Constructor. Grants ADMIN_ROLE and DEFAULT_ADMIN_ROLE to deployer.
     */
    constructor(address initialAdmin) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
    }

    // --- Role Management (by Admin) ---

    /**
     * @dev Grants the CUSTODIAN_ROLE to an FI address.
     * Requires ADMIN_ROLE.
     */
    function grantCustodianRole(address fiAddress) external onlyRole(ADMIN_ROLE) {
        require(fiAddress != address(0), "Custodian cannot be zero address");
        _grantRole(CUSTODIAN_ROLE, fiAddress);
        _custodians.add(fiAddress); // Optional tracking
    }

    /**
     * @dev Revokes the CUSTODIAN_ROLE from an FI address.
     * Requires ADMIN_ROLE.
     */
    function revokeCustodianRole(address fiAddress) external onlyRole(ADMIN_ROLE) {
        require(fiAddress != address(0), "Custodian cannot be zero address");
        _revokeRole(CUSTODIAN_ROLE, fiAddress);
        _custodians.remove(fiAddress); // Optional tracking
    }

    // --- Custodian Actions ---

    /**
     * @dev Registers a user address as being custodied by the caller (FI).
     * Stores associated KYC timestamps.
     * Requires CUSTODIAN_ROLE for the caller (msg.sender).
     * @param userAddress The address of the user wallet being registered.
     * @param kycValidatedTimestamp Timestamp KYC was validated.
     * @param kycExpiresTimestamp Timestamp KYC expires (use 0 if no expiry).
     */
    function registerCustodiedWallet(
        address userAddress,
        uint256 kycValidatedTimestamp,
        uint256 kycExpiresTimestamp
    ) external onlyRole(CUSTODIAN_ROLE) {
        require(userAddress != address(0), "User address cannot be zero");
        // Ensure expiry is not before validation
        require(kycExpiresTimestamp == 0 || kycExpiresTimestamp >= kycValidatedTimestamp, "KYC expiry before validation");
        // Optional: Check if already registered by someone else? Depends on rules.
        // require(_custodyInfo[userAddress].custodian == address(0) || _custodyInfo[userAddress].custodian == _msgSender(), "Wallet already registered by another custodian");

        address custodian = _msgSender();
        _custodyInfo[userAddress] = CustodyData({
            custodian: custodian,
            kycValidatedTimestamp: kycValidatedTimestamp,
            kycExpiresTimestamp: kycExpiresTimestamp
        });

        emit WalletRegistered(userAddress, custodian, kycValidatedTimestamp, kycExpiresTimestamp);
    }

    /**
     * @dev Updates the KYC timestamps for a user address already registered by the caller.
     * Requires CUSTODIAN_ROLE for the caller (msg.sender).
     * @param userAddress The address of the user wallet being updated.
     * @param kycValidatedTimestamp New timestamp KYC was validated.
     * @param kycExpiresTimestamp New timestamp KYC expires (use 0 if no expiry).
     */
    function updateKYCStatus(
        address userAddress,
        uint256 kycValidatedTimestamp,
        uint256 kycExpiresTimestamp
    ) external onlyRole(CUSTODIAN_ROLE) {
        require(userAddress != address(0), "User address cannot be zero");
        address custodian = _msgSender();
        CustodyData storage data = _custodyInfo[userAddress];

        // Ensure the caller is the registered custodian for this user address
        require(data.custodian == custodian, "Caller is not the registered custodian");
        // Ensure expiry is not before validation
        require(kycExpiresTimestamp == 0 || kycExpiresTimestamp >= kycValidatedTimestamp, "KYC expiry before validation");

        data.kycValidatedTimestamp = kycValidatedTimestamp;
        data.kycExpiresTimestamp = kycExpiresTimestamp;

        emit KYCStatusUpdated(userAddress, custodian, kycValidatedTimestamp, kycExpiresTimestamp);
    }

    /**
     * @dev Removes the registration for a user address custodied by the caller.
     * Requires CUSTODIAN_ROLE for the caller (msg.sender).
     * @param userAddress The address of the user wallet being unregistered.
     */
    function unregisterCustodiedWallet(address userAddress) external onlyRole(CUSTODIAN_ROLE) {
        require(userAddress != address(0), "User address cannot be zero");
        address custodian = _msgSender();
        CustodyData storage data = _custodyInfo[userAddress];

        // Ensure the caller is the registered custodian
        require(data.custodian == custodian, "Caller is not the registered custodian");

        delete _custodyInfo[userAddress];
        emit WalletUnregistered(userAddress, custodian);
    }


    // --- View Functions ---

    /**
     * @dev Gets the registered custodian FI for a given user address.
     * @param userAddress The address to query.
     * @return The address of the custodian FI, or address(0) if not registered.
     */
    function getCustodian(address userAddress) external view returns (address) {
        return _custodyInfo[userAddress].custodian;
    }

    /**
     * @dev Gets the KYC status timestamps for a given user address.
     * @param userAddress The address to query.
     * @return validatedTimestamp The timestamp KYC was validated.
     * @return expiresTimestamp The timestamp KYC expires (0 if none).
     */
    function getKYCTimestamps(address userAddress) external view returns (uint256 validatedTimestamp, uint256 expiresTimestamp) {
        CustodyData storage data = _custodyInfo[userAddress];
        return (data.kycValidatedTimestamp, data.kycExpiresTimestamp);
    }

    /**
     * @dev Checks if the KYC for a given user address is currently valid.
     * Considers KYC valid if validation timestamp is set and expiry is 0 or in the future.
     * @param userAddress The address to query.
     * @return True if KYC is considered valid, false otherwise.
     */
    function isKYCValid(address userAddress) external view returns (bool) {
        CustodyData storage data = _custodyInfo[userAddress];
        // Requires validation timestamp to be set AND (expiry is 0 OR expiry is after current time)
        return (data.kycValidatedTimestamp > 0 && (data.kycExpiresTimestamp == 0 || data.kycExpiresTimestamp >= block.timestamp));
    }

    // --- Optional: Functions for tracking custodians ---

    /**
     * @dev Returns the number of registered custodians.
     */
    function custodianCount() external view returns (uint256) {
        return _custodians.length();
    }

    /**
     * @dev Returns the custodian address at a given index.
     */
    function custodianAtIndex(uint256 index) external view returns (address) {
        return _custodians.at(index);
    }

    // --- AccessControl Setup ---
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
