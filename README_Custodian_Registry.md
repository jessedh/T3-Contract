# CustodianRegistry Smart Contract

## Overview

The `CustodianRegistry.sol` contract provides an on-chain registry to manage and track which user wallet addresses are custodied by authorized Financial Institutions (FIs) participating in the T3USD ecosystem. It also stores Know Your Customer (KYC) status information (validation and expiry timestamps) as attested by the custodian FI for each registered wallet.

This contract is designed to work alongside the main `T3Token.sol` (T3USD) contract but operates independently. It allows external parties (users, other contracts, off-chain systems) to query the custodial relationship and KYC validity of an address without burdening the core token transfer logic.

It uses OpenZeppelin's `AccessControl` contract for robust role-based permissioning.

## Features

* **Role-Based Access:** Utilizes `ADMIN_ROLE` and `CUSTODIAN_ROLE`.
* **Custodian Management:** Admins can grant and revoke the `CUSTODIAN_ROLE` to approved FI addresses.
* **Wallet Registration:** Authorized custodians can register user addresses they manage, associating them with KYC timestamps.
* **KYC Status Updates:** Custodians can update KYC timestamps for wallets they manage.
* **Wallet Unregistration:** Custodians can remove registrations for wallets they no longer manage.
* **Public Query Functions:** Provides `view` functions (`getCustodian`, `getKYCTimestamps`, `isKYCValid`) allowing anyone to check the status of an address.
* **Event Emission:** Emits events for significant actions (role changes, registration, updates, unregistration).
* **(Optional) Custodian Tracking:** Includes functionality to list all registered custodian addresses using OpenZeppelin's `EnumerableSet`.

## Roles

* **`DEFAULT_ADMIN_ROLE`:** Has the power to grant/revoke any other role. Typically held by the initial deployer or a secure multi-sig wallet representing the T3 organization.
* **`ADMIN_ROLE`:** Can grant/revoke the `CUSTODIAN_ROLE`. Also typically held by the T3 organization multi-sig.
* **`CUSTODIAN_ROLE`:** Granted to participating FIs. Required to call `registerCustodiedWallet`, `updateKYCStatus`, and `unregisterCustodiedWallet`.

## Setup Instructions

These instructions assume you are working within the T3USD Hardhat project environment.

**1. Prerequisites:**
* Ensure you have completed the general project setup as outlined in the main project README (Node.js, npm/yarn, installed dependencies via `package.json`).
* The `CustodianRegistry.sol` file should be present in your `contracts/` directory.

**2. Compilation:**
* Compile the contract along with other project contracts:
    ```bash
    npx hardhat compile
    ```
* This will generate the ABI and bytecode in the `artifacts/` directory.

**3. Deployment:**
* The `CustodianRegistry` contract needs to be deployed to the desired network (localhost, Sepolia, mainnet, etc.). It should typically be deployed alongside the `T3Token` contract.
* **Deployment Script:** You will need a Hardhat deployment script in your `scripts/` directory (e.g., `deploy.js` or a dedicated script). This script should:
    * Deploy `T3Token` first (if not already deployed).
    * Deploy `CustodianRegistry`, passing the desired initial `ADMIN_ROLE` holder's address (e.g., the deployer address or a T3 organization multi-sig address) to the constructor.
    * Log the deployed addresses of both contracts.
    * Update your `.env` file with the `CUSTODIAN_REGISTRY_ADDRESS`.
    * *(See the `t3_deployment_instructions` Canvas document for an example deployment script handling both contracts).*
* **Deployment Command:** Execute the script using Hardhat:
    ```bash
    # Example for Sepolia
    npx hardhat run scripts/deploy.js --network sepolia
    ```
    *(Replace `deploy.js` with your script name and `sepolia` with your target network).*

**4. Post-Deployment Configuration (CRITICAL):**
* After deployment, the address holding the `ADMIN_ROLE` (initially the deployer specified in the constructor) **must grant the `CUSTODIAN_ROLE`** to the designated wallet addresses of each participating Financial Institution.
* This is done by calling the `grantCustodianRole(fiAddress)` function on the deployed `CustodianRegistry` contract.
* **Example using Hardhat script/console:**
    ```javascript
    // Assuming 'registry' is an ethers.js contract instance connected to the admin signer
    const registryAdmin = owner; // Or the account holding ADMIN_ROLE
    const fi1_address = "0x..."; // Address of the first FI custodian
    const fi2_address = "0x..."; // Address of the second FI custodian

    const CUSTODIAN_ROLE = await registry.CUSTODIAN_ROLE();

    console.log(`Granting CUSTODIAN_ROLE to ${fi1_address}...`);
    let tx = await registry.connect(registryAdmin).grantRole(CUSTODIAN_ROLE, fi1_address);
    await tx.wait();
    console.log(`Granted role to FI 1. Has role? `, await registry.hasRole(CUSTODIAN_ROLE, fi1_address));

    console.log(`Granting CUSTODIAN_ROLE to ${fi2_address}...`);
    tx = await registry.connect(registryAdmin).grantRole(CUSTODIAN_ROLE, fi2_address);
    await tx.wait();
    console.log(`Granted role to FI 2. Has role? `, await registry.hasRole(CUSTODIAN_ROLE, fi2_address));
    ```
* **Without this step, no FI will be able to register wallets.**

## Usage

1.  **FIs (Custodians with `CUSTODIAN_ROLE`):**
    * Call `registerCustodiedWallet(userAddr, validTs, expiryTs)` to register a user wallet they custody and set initial KYC timestamps.
    * Call `updateKYCStatus(userAddr, validTs, expiryTs)` to update KYC info for a wallet they manage.
    * Call `unregisterCustodiedWallet(userAddr)` when they no longer custody the wallet.
2.  **Anyone (Querying Status):**
    * Call `getCustodian(userAddr)` to find the FI custodian address for a user.
    * Call `getKYCTimestamps(userAddr)` to get the validation/expiry dates.
    * Call `isKYCValid(userAddr)` to check if the registered KYC is currently valid based on `block.timestamp`.
    * Call `custodianCount()` and `custodianAtIndex(index)` to list registered custodians (if using the optional

  @media print {
    .ms-editor-squiggler {
        display:none !important;
    }
  }
  .ms-editor-squiggler {
    all: initial;
    display: block !important;
    height: 0px !important;
    width: 0px !important;
  }