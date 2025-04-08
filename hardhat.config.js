// hardhat.config.js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config(); // Loads variables from .env into process.env

// Ensure required environment variables are present
const sepoliaRpcUrl = process.env.SEPOLIA_RPC_URL;
const wallet1PrivateKey = process.env.WALLET1_PRIVATE_KEY;

if (!sepoliaRpcUrl) {
  console.warn("SEPOLIA_RPC_URL not found in .env file. Sepolia network disabled.");
}
if (!wallet1PrivateKey) {
  console.warn("WALLET1_PRIVATE_KEY not found in .env file. Sepolia network disabled.");
}

module.exports = {
  solidity: {
    version: "0.8.20", // Use your specific version
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true, // Correctly enables viaIR compilation pipeline
    },
  },
  networks: {
    hardhat: {
      // Default network, runs in-memory
    },
    localhost: {
      // Network for running 'npx hardhat node'
      url: "http://127.0.0.1:8545/",
      // accounts: Hardhat node provides accounts automatically
      chainId: 31337, // Default chain ID for hardhat node
    },
    // Only include sepolia if credentials are provided
    ...(sepoliaRpcUrl && wallet1PrivateKey && {
      sepolia: {
        url: sepoliaRpcUrl,
        accounts: [wallet1PrivateKey],
        chainId: 11155111, // Sepolia chain ID
      }
    }),
  },
  // Add other configurations like etherscan, gasReporter if needed
  // Example:
  // etherscan: {
  //   apiKey: process.env.ETHERSCAN_API_KEY
  // }
};
