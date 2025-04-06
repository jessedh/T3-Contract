const { ethers } = require("hardhat");

const recipient = "0x511481910D06D9fE31874d9c880f485aFA20d287";
const amount = ethers.parseEther("1000");

async function main() 
{
  const [sender] = await ethers.getSigners();
  const T3Token = await ethers.getContractFactory("T3Token");

  // Replace with your deployed contract address
  const t3 = T3Token.attach("0x698Ab97C38Cd1B7F678203e77142075eaAA53e7D"); 
  

  console.log("Sender address:", sender.address);
  console.log("Sending", ethers.formatEther(amount), "T3 to", recipient);

  const tx = await t3.transfer(recipient, amount);
  await tx.wait();
  console.log("✅ Transfer complete.");

  const metadata = await t3.transferData(recipient);
  console.log("\n📦 Transfer Metadata:");
  console.log("  - HalfLife Duration (s):", metadata.halfLifeDuration.toString());
  const unlockTime = Number(metadata.commitWindowEnd) * 1000;
  console.log("  - Commit Window End:", new Date(unlockTime).toISOString());
  console.log("  - Originator:", metadata.originator);
  console.log("  - Transfer Count:", metadata.transferCount.toString());
  
  const balance = await t3.balanceOf(recipient);
  console.log("  - Recipient Balance:", ethers.formatEther(balance));
  console.log("  - Sender Balance:", ethers.formatEther(await t3.balanceOf(sender.address)));
  console.log("  - Total Supply:", ethers.formatEther(await t3.totalSupply()));
  console.log("  - Contract Address:", t3.target);
  console.log("  - Transfer Data:", metadata);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});