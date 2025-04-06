
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("T3Token - Skeptical Test Suite", function () {
  let T3Token, t3, owner, wallet1, wallet2, wallet3;
  const amount = ethers.parseUnits("1000", 18);

  beforeEach(async function () {
    [owner, wallet1, wallet2, wallet3] = await ethers.getSigners();
    const T3TokenFactory = await ethers.getContractFactory("T3Token");
    t3 = await T3TokenFactory.deploy(owner.address);
    await t3.waitForDeployment();

    await t3.connect(owner).transfer(wallet1.address, amount);
  });

  it("should transfer tokens from wallet1 to wallet2", async () => {
    await expect(() => t3.connect(wallet1).transfer(wallet2.address, amount))
      .to.changeTokenBalances(t3, [wallet1, wallet2], [amount.mul(-1n), amount]);
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

    const b1 = await t3.balanceOf(wallet1.address);
    const b2 = await t3.balanceOf(wallet2.address);

    expect(b1).to.equal(amount);
    expect(b2).to.equal(0n);
  });

  it("should not allow sender to reverse their own transfer", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);

    await expect(
      t3.connect(wallet1).reverseTransfer(wallet1.address, wallet2.address, amount)
    ).to.be.reverted;
  });

  it("should not allow reversal after HalfLife ends", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);

    await ethers.provider.send("evm_increaseTime", [7200]);
    await ethers.provider.send("evm_mine");

    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount)
    ).to.be.reverted;
  });

  it("should fail if reversal amount is incorrect", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);

    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount.div(2))
    ).to.be.reverted;
  });

  it("should fail if recipient tries to reverse to the wrong sender", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);

    await expect(
      t3.connect(wallet2).reverseTransfer(wallet2.address, wallet3.address, amount)
    ).to.be.reverted;
  });

  it("should fail on second reversal of same funds", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);

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
    const amount2 = ethers.parseUnits("500", 18);
    await t3.connect(wallet1).transfer(wallet2.address, amount2);
    await t3.connect(wallet1).transfer(wallet2.address, amount2);

    const metadata = await t3.transferData(wallet2.address);
    expect(metadata.transferCount).to.equal(2);
  });

  it("should keep total supply constant", async () => {
    const supplyBefore = await t3.totalSupply();
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);
    const supplyAfter = await t3.totalSupply();

    expect(supplyAfter).to.equal(supplyBefore);
  });

  it("should maintain or clear metadata after reversal", async () => {
    await t3.connect(wallet1).transfer(wallet2.address, amount);
    await t3.connect(wallet2).reverseTransfer(wallet2.address, wallet1.address, amount);

    const metadata = await t3.transferData(wallet2.address);
    expect(metadata.transferCount).to.equal(1);
    expect(metadata.originator).to.not.equal(ethers.ZeroAddress);
  });
});
