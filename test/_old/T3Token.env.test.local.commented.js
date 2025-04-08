const hre = require("hardhat");
const { ethers } = hre;
const { expect } = require("chai");

describe("T3Token - Skeptical Test Suite (Localhost)", function () {
  let t3, wallet1, wallet2, wallet3;
  let amount;

  beforeEach(async function () {
    [wallet1, wallet2, wallet3] = await ethers.getSigners();
    amount = ethers.utils.parseUnits("1000", 18);
    
    // Connect to already deployed T3Token contract on localhost
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
    await new Promise((res) => setTimeout(res, 200)); // ensure nonce order

    await expect(
      t3.connect(wallet2).transfer(wallet3.address, amount)
    ).to.be.reverted;
  });

  it("should allow reversal from wallet2 to wallet1", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await new Promise((res) => setTimeout(res, 200)); // allow next tx

    const reverseTx = await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    await reverseTx.wait();

    const final1 = await t3.balanceOf(wallet1.address);
    const final2 = await t3.balanceOf(wallet2.address);

    expect(final1).to.be.gt(0);
    expect(final2).to.equal(0n);
  });

  it("should not allow sender to reverse their own transfer", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await new Promise((res) => setTimeout(res, 200));

    await expect(
      t3.connect(wallet1).reverseTransfer(wallet1.address, wallet2.address, amount)
    ).to.be.reverted;
  });

  it("should not allow reversal after HalfLife ends", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);

    // Simulate passage of time beyond HalfLife
    await ethers.provider.send("evm_increaseTime", [7200]);
    await ethers.provider.send("evm_mine");

    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should fail if reversal amount is incorrect", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    const wrongAmount = amount.div(2);

    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, wrongAmount)
    ).to.be.reverted;
  });

  it("should fail if recipient tries to reverse to wrong sender", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet3.address, amount)
    ).to.be.reverted;
  });

  it("should fail on second reversal of same funds", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    await new Promise((res) => setTimeout(res, 200));

    // Should fail now — already reversed
    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should prevent third-party wallet from spoofing reversal", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);

    await expect(
      t3.connect(wallet3).reverseTransfer(wallet2.address, wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should isolate metadata if multiple transfers occur", async () => {
    const start = (await t3.transferData(wallet2.address)).transferCount;

    const half = amount.div(2);
    await t3.connect(wallet1).transfer(wallet2.address, half);
    await new Promise((res) => setTimeout(res, 200));
    await t3.connect(wallet1).transfer(wallet2.address, half);
    await new Promise((res) => setTimeout(res, 200));

    const end = (await t3.transferData(wallet2.address)).transferCount;
    expect(end).to.equal(start + 2n);
  });

  it("should keep total supply constant after transfer and reversal", async () => {
    const supplyBefore = await t3.totalSupply();

    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);

    const supplyAfter = await t3.totalSupply();
    expect(supplyAfter).to.equal(supplyBefore);
  });

  it("should increment transferCount metadata after reversal", async () => {
    const before = (await t3.transferData(wallet2.address)).transferCount;

    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await new Promise((res) => setTimeout(res, 200));
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);

    const after = (await t3.transferData(wallet2.address)).transferCount;
    expect(after).to.be.gte(before + 1n);
  });
});
