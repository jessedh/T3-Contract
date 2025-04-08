
require("dotenv").config();
const { expect } = require("chai");
const { ethers: rawEthers } = require("ethers"); // for parseUnits, etc.
const hre = require("hardhat");
const { ethers } = hre;

describe("T3Token - Skeptical Test Suite (Localhost)", function () {
  let t3, wallet1, wallet2, wallet3;
  let amount;

  beforeEach(async function () {
    const provider = new rawEthers.JsonRpcProvider(process.env.RPC_URL);
    wallet1 = new rawEthers.Wallet(process.env.WALLET1_PRIVATE_KEY, provider);
    wallet2 = new rawEthers.Wallet(process.env.WALLET2_PRIVATE_KEY, provider);
    wallet3 = new rawEthers.Wallet(process.env.WALLET3_PRIVATE_KEY, provider);
    amount = rawEthers.parseUnits("1000", 18);
    t3 = await ethers.getContractAt("T3Token", process.env.T3_CONTRACT_ADDRESS, wallet1);
  });

  it("should transfer tokens from wallet1 to wallet2", async () => {
    const before1 = await t3.balanceOf(wallet1.address);
    const before2 = await t3.balanceOf(wallet2.address);

    const tx = await t3.connect(wallet1).transfer(wallet2.address, amount);
    await tx.wait();

    const after1 = await t3.balanceOf(wallet1.address);
    const after2 = await t3.balanceOf(wallet2.address);

    expect(after1).to.equal(before1.sub(amount));
    expect(after2).to.equal(before2.add(amount));
  });

  it("should fail if sender has insufficient balance", async () => {
    await expect(
      t3.connect(wallet2).transfer(wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should prevent forward transfer before HalfLife ends", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await expect(
      t3.connect(wallet2).transfer(wallet3.address, amount)
    ).to.be.reverted;
  });

  it("should allow reversal from wallet2 to wallet1", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    const tx = await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    await tx.wait();

    const final1 = await t3.balanceOf(wallet1.address);
    const final2 = await t3.balanceOf(wallet2.address);

    expect(final1).to.be.gt(0);
    expect(final2).to.equal(0n);
  });

  it("should not allow sender to reverse their own transfer", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
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
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    const halfAmount = amount.div(2);
    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, halfAmount)
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
    const initialCount = (await t3.transferData(wallet2.address)).transferCount;
    const half = amount.div(2);
    await t3.connect(wallet1).transfer(wallet2.address, half);
    await t3.connect(wallet1).transfer(wallet2.address, half);

    const finalCount = (await t3.transferData(wallet2.address)).transferCount;
    expect(finalCount).to.equal(initialCount + 2n);
  });

  it("should maintain total supply across transfers and reversals", async () => {
    const supplyBefore = await t3.totalSupply();
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    const supplyAfter = await t3.totalSupply();

    expect(supplyAfter).to.equal(supplyBefore);
  });

  it("should increment transferCount after reversal", async () => {
    const before = (await t3.transferData(wallet2.address)).transferCount;
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    const after = (await t3.transferData(wallet2.address)).transferCount;

    expect(after).to.be.gte(before + 1n);
  });
});
