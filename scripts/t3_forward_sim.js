const { ethers } = require("hardhat");

const recipientKey = process.env.RECIPIENT_PRIVATE_KEY; // Must be funded on Sepolia
const recipient = new ethers.Wallet(recipientKey, ethers.provider);
const amount = ethers.parseEther("100");

async function main() {
  const T3Token = await ethers.getContractFactory("T3Token", recipient);
  const t3 = T3Token.attach("0x698Ab97C38Cd1B7F678203e77142075eaAA53e7D");

  const thirdParty = "0x363782E89137df5c89bd917DE484fd2204998319"; // T3 Test Account 03

  console.log("Attempting to forward 100 T3 from recipient to third party...");
  try {
    const tx = await t3.connect(recipient).transfer(thirdParty, amount);
    await tx.wait();
    console.log("❌ Forward transfer succeeded (this is NOT expected).");
  } catch (err) {
    console.log("✅ Forward transfer failed as expected (locked by HalfLife).");
    console.error("Revert reason:", err.message);
  }
}

main().catch(console.error);