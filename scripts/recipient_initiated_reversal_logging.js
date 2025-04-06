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

  let metadata = await t3FromWallet1.transferData(wallet2.address);
  console.log("📦 Transfer Metadata:", metadata);
  console.log("  - Recipient Balance:", ethers.formatEther(await t3FromWallet1.balanceOf(wallet2.address)));
  console.log("  - Sender Balance:", ethers.formatEther(await t3FromWallet1.balanceOf(wallet1.address)));
  console.log("  - Total Supply:", ethers.formatEther(await t3FromWallet1.totalSupply()));
  console.log("  - Contract Address:", t3FromWallet1.target);

  const hash = ethers.solidityPackedKeccak256(["uint256", "address"], [amount, wallet2.address]);
	  
  console.log("\n🔁 2. Attempting reversal from Wallet2 (recipient) back to Wallet1...");
  const T3Token2 = await ethers.getContractFactory("T3Token", wallet2);
  const t3FromWallet2 = T3Token2.attach(contractAddress);
  //set explicit gas fee
  const tx2 = await t3FromWallet2.reverseTransfer
	(wallet2.address, amount, hash, 
		{
		gasLimit: 300000,    // Explicit gas limit
		maxPriorityFeePerGas: ethers.parseUnits('3', 'gwei'), 
		maxFeePerGas: ethers.parseUnits('100', 'gwei')
		}
	);
await tx2.wait();
  console.log("pending reversal....")
  await tx2.wait();
  console.log("✅ Reversal from recipient successful!");

  console.log("  - Recipient Balance After Reversal:", ethers.formatEther(await t3FromWallet2.balanceOf(wallet2.address)));
  console.log("  - Sender Balance After Reversal:", ethers.formatEther(await t3FromWallet2.balanceOf(wallet1.address)));
}

main().catch((error) => {
  console.error("❌ Error:", error);
  process.exitCode = 1;
});