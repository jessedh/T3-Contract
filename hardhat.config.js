require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
require("solidity-coverage");
module.exports = {
  solidity: "0.8.20",
  networks: {
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL,
      accounts: [process.env.WALLET1_PRIVATE_KEY]
    }
  }
};