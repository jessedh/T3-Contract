require("dotenv").config();
const { ethers } = require("hardhat");

//async function logBalances function in footer

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
  const wallet1 = new ethers.Wallet(process.env.WALLET1_PRIVATE_KEY, provider);
  const wallet2 = new ethers.Wallet(process.env.WALLET2_PRIVATE_KEY, provider);
  const wallet3 = new ethers.Wallet(process.env.WALLET3_PRIVATE_KEY, provider);

  const t3 = await ethers.getContractAt("T3Token", process.env.T3_CONTRACT_ADDRESS, wallet1);
  const amount = ethers.parseUnits("1000", 18);

  console.log(`\n🔁 1. Transferring from Wallet1 (${wallet1.address}) to Wallet2 (${wallet2.address})...`);
  const tx = await t3.connect(wallet1).transfer(wallet2.address, amount);
  await tx.wait();
  console.log("✅ Transfer complete");

  const metadata = await t3.transferData(wallet2.address);
  console.log("\n📦 Transfer Metadata:");
  console.log("  - HalfLife Duration (s):", metadata.halfLifeDuration.toString());
  const unlockTime = Number(metadata.commitWindowEnd) * 1000;
  console.log("  - Commit Window End:", new Date(unlockTime).toISOString());
  console.log("  - Originator:", metadata.originator);
  console.log("  - Transfer Count:", metadata.transferCount.toString());
  console.log("🔑 Reversal Hash:", metadata.reversalHash);

  await logBalances(t3, wallet1, "wallet1", "After attempted Wallet1 ➡️ Wallet2",wallet2, "wallet2");

  console.log(`\n🚫 2. Attempting forward transfer from Wallet2 ➡️ Wallet3 (${wallet3.address})...`);
  try {
    const failTx = await t3.connect(wallet2).transfer(wallet3.address, amount.div(2));
    await failTx.wait();
    console.error("❌ Unexpected: Forward transfer succeeded.");
  } catch (err) {
    console.log("✅ Forward transfer blocked by HalfLife rule.");
  }

  await logBalances(t3, wallet2, "wallet2", "After attempted Wallet2 ➡️ Wallet3",wallet3, "wallet3");

  console.log(`\n🔁 3. Reversing transfer from Wallet2 ➡️ Wallet1 (${wallet1.address})...`);
  try {
    const reversal = await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    await reversal.wait();
    console.log("✅ Reversal succeeded.");
  } catch (err) {
    console.error("❌ Reversal failed:", err.message.split("\n")[0]);
  }

  console.log(`\n🔁 4. Reversing transfer from Wallet1 ➡️ Wallet2 (${wallet1.address})...`);
	try 
		{
			const reversal = await t3.connect(wallet1).reverseTransfer(wallet1.address, wallet2.address, amount);
			await reversal.wait();
			console.log("❌ Reversal succeed (should not be able to re-reverse)");
		} 
	catch (err) 
		{
			console.error("✅ Reversal failed (should not be able to re-reverse): ", err.message.split("\n")[0]);
		}

  await logBalances(t3, wallet1, "wallet1", "Final Wallet1");
  await logBalances(t3, wallet2, "wallet2", "Final Wallet2");
  await logBalances(t3, wallet3, "wallet3", "Final Wallet3");
}

//THIS IS THE FUNCTION THAT RETURNS MY BALANCES
async function logBalances(t3, w1, w1_label, transaction_label, w2 = null, w2_label = "Wallet 2") {
  const b1 = await t3.balanceOf(w1.address);
  const total = await t3.totalSupply();

  console.log(`\n🔍 ${transaction_label}:`);
  console.log(` ${w1_label}: - ${w1.address.substring(0, 10)}...: ${ethers.formatEther(b1)} T3`);

  if (w2) 
  {
    const b2 = await t3.balanceOf(w2.address);
    console.log(` ${w2_label}: - ${w2.address.substring(0, 10)}...: ${ethers.formatEther(b2)} T3`);
  }

  console.log(`  - Total Supply: ${ethers.formatEther(total)} T3\n`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
