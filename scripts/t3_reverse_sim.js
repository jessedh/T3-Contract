const { ethers } = require("hardhat");

async function main() {
  const [sender] = await ethers.getSigners();
  const t3 = await ethers.getContractAt("T3Token", "0x698Ab97C38Cd1B7F678203e77142075eaAA53e7D");


  const recipient = "0x511481910D06D9fE31874d9c880f485aFA20d287";
  const amount = ethers.parseEther("1000");

  const hash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "address"], [amount, recipient]));
  console.log("🔑 Reversal Hash (simulated):", hash);

  console.log("🔁 Attempting reversal transfer from recipient to sender...");
  const tx = await t3.reverseTransfer("0x19d5Dab464B7C6a4d95f16898f133559C123F253", amount, hash);
  await tx.wait();
  console.log("✅ Reverse transfer complete!");
}

main().catch(console.error);

