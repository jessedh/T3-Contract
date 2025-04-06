const { ethers } = require("hardhat");
require("dotenv").config();

const wallet1 = new ethers.Wallet(process.env.WALLET1_PRIVATE_KEY, ethers.provider);
const wallet2 = new ethers.Wallet(process.env.WALLET2_PRIVATE_KEY, ethers.provider);
const wallet3 = new ethers.Wallet(process.env.WALLET3_PRIVATE_KEY, ethers.provider);
const contractAddress = process.env.T3_CONTRACT_ADDRESS;
const amount = ethers.parseEther("1000");

async function main() {
  const T3Token1 = await ethers.getContractFactory("T3Token", wallet1);
  const t3FromWallet1 = T3Token1.attach(contractAddress);

  console.log("🔁 1. Transferring from Wallet1 to Wallet2...");
  const tx1 = await t3FromWallet1.transfer(wallet2.address, amount);
  await tx1.wait();
  console.log("✅ Transfer complete");
  const balance = await t3.balanceOf(wallet2);
  console.log("  - Recipient Balance:", ethers.formatEther(balance));
  console.log("  - Sender Balance:", ethers.formatEther(await t3.balanceOf(wallet1.address)));
  console.log("  - Total Supply:", ethers.formatEther(await t3.totalSupply()));
  console.log("  - Contract Address:", t3.target); // ✅
  console.log("  - Transfer Data:", metadata);

  const metadata = await t3FromWallet1.transferData(wallet2.address);
  const unlockTime = Number(metadata.commitWindowEnd) * 1000;
  console.log("🔒 HalfLife Lock Until:", new Date(unlockTime).toISOString());

  console.log("\n🚫 2. Attempting forward transfer from Wallet2 to Wallet3 (should fail)...");
  const T3Token2 = await ethers.getContractFactory("T3Token", wallet2);
  const t3FromWallet2 = T3Token2.attach(contractAddress);
  try {
    const tx2 = await t3FromWallet2.transfer(wallet3.address, amount);
    await tx2.wait();
    console.log("❌ Unexpected: Forward transfer succeeded (this should not happen)");
  } catch (err) {
    console.log("✅ Forward transfer correctly failed due to HalfLife lock.");
  }

const hash = ethers.solidityPackedKeccak256(["uint256", "address"], [amount, wallet2.address]);

//  const hash = ethers.keccak256(
//    ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "address"], [amount, wallet2.address])
//  );

  console.log("\n🔁 3. Attempting reversal transfer from Wallet1 (sender)...");
  try {
    const tx3 = await t3FromWallet1.reverseTransfer(wallet2.address, amount, hash);
    await tx3.wait();
    console.log("✅ Reversal from sender successful!");
  } catch (err) {
    console.error("❌ Reversal failed from sender:", err);
  }

  console.log("\n🔁 4. Attempting reversal from Wallet2 (recipient) back to Wallet1...");
  try {
    const tx4 = await t3FromWallet2.reverseTransfer(wallet2.address, amount, hash);
    await tx4.wait();
    console.log("✅ Reversal from recipient successful!");
  } catch (err) {
    console.error("❌ Reversal failed from recipient:", err);
  }
}

main().catch((error) => {
  console.error("❌ Error:", error);
  process.exitCode = 1;
});