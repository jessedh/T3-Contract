
require("dotenv").config();
const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;

describe("T3Token - Skeptical Test Suite (Localhost)", function () {
  let t3, wallet1, wallet2, wallet3;
  let amount;

  const delay = (ms) => new Promise((res) => setTimeout(res, ms));

  beforeEach(async function () {
    const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);

    wallet1 = new ethers.Wallet(process.env.WALLET1_PRIVATE_KEY, provider);
    wallet2 = new ethers.Wallet(process.env.WALLET2_PRIVATE_KEY, provider);
    wallet3 = new ethers.Wallet(process.env.WALLET3_PRIVATE_KEY, provider);

    amount = await hre.ethers.parseUnits("1000", 18);
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

  it("should fail if sender has insufficient balance", async () => {
    await expect(
      t3.connect(wallet2).transfer(wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should prevent forward transfer before HalfLife ends", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await delay(200);
    await expect(
      t3.connect(wallet2).transfer(wallet3.address, amount)
    ).to.be.reverted;
  });

  it("should allow reversal from wallet2 to wallet1", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await delay(200);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    const final1 = await t3.balanceOf(wallet1.address);
    const final2 = await t3.balanceOf(wallet2.address);

    expect(final1).to.be.gt(0);
    expect(final2).to.equal(0n);
  });

  it("should not allow sender to reverse their own transfer", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await delay(200);
    await expect(
      t3.connect(wallet1).reverseTransfer(wallet1.address, wallet2.address, amount)
    ).to.be.reverted;
  });

  it("should not allow reversal after HalfLife expires", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await ethers.provider.send("evm_increaseTime", [7200]);
    await ethers.provider.send("evm_mine");
    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should fail if reversal amount is incorrect", async () => {
    const wrongAmount = amount / BigInt(2);
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, wrongAmount)
    ).to.be.reverted;
  });

  it("should fail if reversing to wrong sender", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet3.address, amount)
    ).to.be.reverted;
  });

  it("should fail on double reversal attempt", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    await delay(200);
    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should prevent third-party spoof reversal", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await expect(
      t3.connect(wallet3).reverseTransfer(wallet2.address, wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should increment transferCount metadata after multiple transfers", async () => {
    const initial = await t3.transferData(wallet2.address);
    const half = amount / BigInt(2);
    await t3.connect(wallet1).transfer(wallet2.address, half);
    await delay(200);
    await t3.connect(wallet1).transfer(wallet2.address, half);
    const after = await t3.transferData(wallet2.address);
    expect(after.transferCount).to.equal(initial.transferCount + 2n);
  });

  it("should maintain total supply across transfers and reversals", async () => {
    const supplyBefore = await t3.totalSupply();
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    const supplyAfter = await t3.totalSupply();
    expect(supplyAfter).to.equal(supplyBefore);
  });

  it("should increment transferCount after reversal", async () => {
    const before = await t3.transferData(wallet2.address);
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await delay(200);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    const after = await t3.transferData(wallet2.address);
    expect(after.transferCount).to.be.gte(before.transferCount + 1n);
  });
});
