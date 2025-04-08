
require("dotenv").config();
const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;

describe("T3Token - Skeptical Test Suite (Localhost)", function () {
  let t3, wallet1, wallet2, wallet3;
  let amount;

  // Utility delay to avoid nonce collision issues
  const delay = (ms) => new Promise((res) => setTimeout(res, ms));

  beforeEach(async function () {
    // Use Hardhat's built-in accounts via private keys in .env
    const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);

    wallet1 = new ethers.Wallet(process.env.WALLET1_PRIVATE_KEY, provider);
    wallet2 = new ethers.Wallet(process.env.WALLET2_PRIVATE_KEY, provider);
    wallet3 = new ethers.Wallet(process.env.WALLET3_PRIVATE_KEY, provider);

    // Parse token amount using Hardhat's ethers BigNumber
    amount = await hre.ethers.parseUnits("1000", 18);

    // Get deployed contract
    t3 = await ethers.getContractAt("T3Token", process.env.T3_CONTRACT_ADDRESS, wallet1);
  });

  it("should transfer tokens from wallet1 to wallet2", async () => {
    const before1 = await t3.balanceOf(wallet1.address);
    const before2 = await t3.balanceOf(wallet2.address);

    const tx = await t3.connect(wallet1).transfer(wallet2.address, amount);
    await tx.wait();

    const after1 = await t3.balanceOf(wallet1.address);
    const after2 = await t3.balanceOf(wallet2.address);

    expect(after1).to.equal(before1 - amount);
    expect(after2).to.equal(before2 + amount);
  });
});
