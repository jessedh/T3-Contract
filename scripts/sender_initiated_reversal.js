const { ethers } = require("hardhat");
require("dotenv").config();

const wallet1 = new ethers.Wallet(process.env.WALLET1_PRIVATE_KEY, ethers.provider);
const wallet2 = new ethers.Wallet(process.env.WALLET2_PRIVATE_KEY, ethers.provider);
const contractAddress = process.env.T3_CONTRACT_ADDRESS;
const amount = ethers.parseEther("1000");

async function main() {
  const T3Token1 = await ethers.getContractFactory("T3Token", wallet1);
  const t3FromWallet1 = T3Token1.attach(contractAddress);

  console.log("🔁 1. Transferring from Wallet1 to Wallet2...");
  const tx1 = await t3FromWallet1.transfer(wallet2.address, amount);
  await tx1.wait();
  console.log("✅ Transfer complete");

  const hash = ethers.solidityPackedKeccak256(["uint256", "address"], [amount, wallet2.address]);

  console.log("\n🔁 2. Attempting reversal from Wallet1 (sender)...");
  const tx2 = await t3FromWallet1.reverseTransfer(wallet2.address, amount, hash);
  await tx2.wait();
  console.log("✅ Reversal from sender successful!");
}

main().catch((error) => {
  console.error("❌ Error:", error);
  process.exitCode = 1;
});