// hardhat.config.js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config(); // Loads variables from .env into process.env
require("hardhat-gas-reporter"); // <--- Added gas reporter plugin

// Ensure required environment variables are present
const sepoliaRpcUrl = process.env.SEPOLIA_RPC_URL;
const wallet1PrivateKey = process.env.WALLET1_PRIVATE_KEY;
const coinMarketCapApiKey = process.env.COINMARKETCAP_API_KEY; // For gas price conversion
const etherscanApiKey = process.env.ETHERSCAN_API_KEY; // For Etherscan integration

if (!sepoliaRpcUrl) {
  console.warn("SEPOLIA_RPC_URL not found in .env file. Sepolia network disabled.");
}
if (!wallet1PrivateKey) {
  console.warn("WALLET1_PRIVATE_KEY not found in .env file. Sepolia network disabled.");
}
if (!coinMarketCapApiKey) {
  console.warn("COINMARKETCAP_API_KEY not found in .env file. Gas price conversion to USD disabled.");
}
// Add warning for Etherscan key if planning to use it
// if (!etherscanApiKey) {
//   console.warn("ETHERSCAN_API_KEY not found in .env file.");
// }


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

  // --- Gas Reporter Configuration ---
  gasReporter: {
    // Set enabled to false to disable running the reporter by default
    // You can enable it when needed by setting environment variable: REPORT_GAS=true
    enabled: (process.env.REPORT_GAS === 'true') ? true : false,
    currency: 'USD', // Show gas costs estimated in USD
    coinmarketcap: coinMarketCapApiKey, // API key to fetch gas price info
    outputFile: 'gas-report.txt', // Save the report to a file
    noColors: true, // Disable colors in the output file
    // excludeContracts: [], // Optional: Add contract names to exclude
  },
  // ---------------------------------

  // --- Etherscan Configuration (Example) ---
  // etherscan: {
  //   apiKey: etherscanApiKey,
  // },
  // ---------------------------------------
};
