# T3 Contract Suite (Patched)

## Overview

This project implements the `T3Token` smart contract with enhanced features for compliance and reversibility using a HalfLife mechanism.

### Key Features
- **ERC20 Stablecoin** with `Ownable` access control.
- **HalfLife Lock**: Locks newly transferred funds from being forwarded for a defined period.
- **Reversible Transfers**: Funds can be reversed during the HalfLife window by either the original sender or the recipient.
- **Reversal Hash Check**: Verifies transaction integrity using a `keccak256` hash of originator, recipient, and amount.

---

## 📁 Project Structure

```
T3-Contract-Patched/
│
├── contracts/
│   └── T3Token.sol         # Main Solidity contract
│
├── scripts/
│   └── t3_reversal_end_to_end.js   # End-to-end test script
│
└── README.md
```

---

## ⚙️ Environment Setup

### Required `.env` variables

```env
RPC_URL=https://sepolia.infura.io/v3/YOUR_PROJECT_ID
WALLET1_PRIVATE_KEY=0x...
WALLET2_PRIVATE_KEY=0x...
WALLET3_PRIVATE_KEY=0x...
T3_CONTRACT_ADDRESS=0x...  # Populated after deployment
```

---

## 🚀 Deployment

Run the deploy script to deploy the contract and automatically update your `.env` file:

```bash
npx hardhat run scripts/deploy.js --network sepolia
```

---

## ✅ Running the End-to-End Test

After deploying and setting up the `.env`, run the test script:

```bash
npx hardhat run scripts/t3_reversal_end_to_end.js --network sepolia
```

The test performs:
1. Wallet1 ➡️ Wallet2 (1000 T3 transfer)
2. Wallet2 ➡️ Wallet3 (should fail if HalfLife is active)
3. Wallet2 ➡️ Wallet1 (reversal)

---

## 🛡️ Notes

- Make sure `T3Token.sol` is compiled and up to date.
- Ensure wallet accounts have sufficient ETH to pay gas.
- If errors persist, check the contract ABI and network sync.

---

Built for reversible compliance in tokenized systems.
