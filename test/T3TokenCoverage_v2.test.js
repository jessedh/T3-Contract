// test/T3TokenCoverage.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("T3Token Contract - Coverage Tests", function () {
    // --- Contract Instances and Signers ---
    let T3Token;
    let t3Token;
    let owner, addr1, addr2, treasury, nonOwner, attestor, pauser, minter, burner; // Added more roles
    let addrs;

    // --- Constants ---
    const DECIMALS = 18;
    const ZERO_ADDRESS = ethers.ZeroAddress;
    const DEFAULT_HALF_LIFE_DURATION = 3600; // Match contract default
    const BASIS_POINTS = 10000n;
    const MAX_FEE_PERCENT = 500n; // Assumes 5% (500 BP) - Match contract
    const MIN_FEE_WEI = 1n; // Assuming contract MIN_FEE = 1 means 1 wei

    // Access Control Roles (bytes32)
    let ADMIN_ROLE;
    let MINTER_ROLE;
    let BURNER_ROLE;
    let PAUSER_ROLE;
    let DEFAULT_ADMIN_ROLE; // Usually bytes32(0) but get from contract

    // Helper Functions
    const toTokenAmount = (value) => ethers.parseUnits(value.toString(), DECIMALS);

    // --- Fixture for Deployment ---
    async function deployT3TokenFixture() {
        [owner, addr1, addr2, treasury, nonOwner, attestor, pauser, minter, burner, ...addrs] = await ethers.getSigners();
        T3Token = await ethers.getContractFactory("T3Token");
        // Deploy contract, owner gets ADMIN and PAUSER roles by default in this setup
        t3Token = await T3Token.deploy(owner.address, treasury.address);

        // Get role identifiers from contract
        ADMIN_ROLE = await t3Token.ADMIN_ROLE();
        MINTER_ROLE = await t3Token.MINTER_ROLE();
        BURNER_ROLE = await t3Token.BURNER_ROLE();
        PAUSER_ROLE = await t3Token.PAUSER_ROLE();
        DEFAULT_ADMIN_ROLE = await t3Token.DEFAULT_ADMIN_ROLE(); // Get default admin role hash

        // Pre-grant some roles for testing convenience
        await t3Token.connect(owner).grantRole(MINTER_ROLE, minter.address);
        await t3Token.connect(owner).grantRole(BURNER_ROLE, burner.address);
        // Grant PAUSER_ROLE to separate account if needed for testing separation
        // await t3Token.connect(owner).grantRole(PAUSER_ROLE, pauser.address);

        // Distribute some tokens
        await t3Token.connect(owner).transfer(addr1.address, toTokenAmount(10000)); // Increased amount
        await t3Token.connect(owner).transfer(addr2.address, toTokenAmount(10000));

        // Advance time well past HalfLife from these setup transfers
        await time.increase(DEFAULT_HALF_LIFE_DURATION * 2);

        return { t3Token, owner, addr1, addr2, treasury, nonOwner, attestor, pauser, minter, burner, addrs };
    }

    // --- Load Fixture Before Each Test ---
    beforeEach(async function () {
        // Using loadFixture speeds up tests by resetting state instead of redeploying
        const fixture = await loadFixture(deployT3TokenFixture);
        t3Token = fixture.t3Token;
        owner = fixture.owner; // Also holds ADMIN, DEFAULT_ADMIN, PAUSER
        addr1 = fixture.addr1;
        addr2 = fixture.addr2;
        treasury = fixture.treasury;
        nonOwner = fixture.nonOwner;
        attestor = fixture.attestor; // Example role placeholder
        pauser = fixture.pauser;     // Example role placeholder
        minter = fixture.minter;     // Has MINTER_ROLE
        burner = fixture.burner;     // Has BURNER_ROLE
        addrs = fixture.addrs;
    });

    // ========================================
    // Access Control Tests
    // ========================================
    describe("Access Control", function () {
        it("Should set deployer as DEFAULT_ADMIN_ROLE and ADMIN_ROLE", async function () {
            expect(await t3Token.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
            expect(await t3Token.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
        });

        it("Should allow ADMIN_ROLE to grant MINTER_ROLE", async function () {
            await expect(t3Token.connect(owner).grantRole(MINTER_ROLE, addr1.address))
                .to.not.be.reverted;
            expect(await t3Token.hasRole(MINTER_ROLE, addr1.address)).to.be.true;
        });

        it("Should prevent non-ADMIN_ROLE from granting MINTER_ROLE", async function () {
            await expect(t3Token.connect(nonOwner).grantRole(MINTER_ROLE, addr1.address))
                .to.be.revertedWithCustomError(t3Token, "AccessControlUnauthorizedAccount")
                .withArgs(nonOwner.address, DEFAULT_ADMIN_ROLE); // Granting roles requires DEFAULT_ADMIN_ROLE
        });

         it("Should allow ADMIN_ROLE to revoke MINTER_ROLE", async function () {
            await t3Token.connect(owner).grantRole(MINTER_ROLE, addr1.address);
            expect(await t3Token.hasRole(MINTER_ROLE, addr1.address)).to.be.true;
            await expect(t3Token.connect(owner).revokeRole(MINTER_ROLE, addr1.address))
                .to.not.be.reverted;
            expect(await t3Token.hasRole(MINTER_ROLE, addr1.address)).to.be.false;
        });

         // Add similar tests for BURNER_ROLE, PAUSER_ROLE, ADMIN_ROLE management
    });


    // ========================================
    // Minting Tests
    // ========================================
    describe("Minting", function () {
        const mintAmount = toTokenAmount(500);

        it("Should allow MINTER_ROLE to mint tokens", async function () {
            const initialSupply = await t3Token.totalSupply();
            const initialRecipientBalance = await t3Token.balanceOf(addr1.address);
            const initialMinterMinted = await t3Token.mintedByMinter(minter.address);

            await expect(t3Token.connect(minter).mint(addr1.address, mintAmount))
                .to.emit(t3Token, "TokensMinted")
                .withArgs(minter.address, addr1.address, mintAmount);

            expect(await t3Token.totalSupply()).to.equal(initialSupply + mintAmount);
            expect(await t3Token.balanceOf(addr1.address)).to.equal(initialRecipientBalance + mintAmount);
            expect(await t3Token.mintedByMinter(minter.address)).to.equal(initialMinterMinted + mintAmount);
        });

        it("Should prevent non-MINTER_ROLE from minting", async function () {
            await expect(t3Token.connect(nonOwner).mint(addr1.address, mintAmount))
                .to.be.revertedWithCustomError(t3Token, "AccessControlUnauthorizedAccount")
                .withArgs(nonOwner.address, MINTER_ROLE);
        });

        it("Should prevent minting zero amount", async function () {
             await expect(t3Token.connect(minter).mint(addr1.address, 0))
                .to.be.revertedWith("Mint amount must be positive");
        });

        it("Should prevent minting to zero address", async function () {
             await expect(t3Token.connect(minter).mint(ZERO_ADDRESS, mintAmount))
                .to.be.revertedWith("Mint to the zero address");
        });

         // Add tests for minting allowance if that model is implemented later
    });

    // ========================================
    // Burning Tests
    // ========================================
     describe("Burning", function () {
        const burnAmount = toTokenAmount(100);
        const initialUserBalance = toTokenAmount(1000); // From beforeEach transfer (approx)

        beforeEach(async function() {
            // Ensure addr1 has enough balance for burn tests
            const currentBalance = await t3Token.balanceOf(addr1.address);
            if (currentBalance < burnAmount) {
                 await t3Token.connect(owner).transfer(addr1.address, burnAmount - currentBalance + toTokenAmount(1)); // Top up if needed
            }
             // Ensure addr1 approves burner for burnFrom tests
             await t3Token.connect(addr1).approve(burner.address, burnAmount);
        });

        // --- burn() ---
        it("Should allow user to burn their own tokens", async function () {
            const initialSupply = await t3Token.totalSupply();
            const initialBalance = await t3Token.balanceOf(addr1.address);

            await expect(t3Token.connect(addr1).burn(burnAmount))
                .to.emit(t3Token, "Transfer") // Burn emits Transfer to address(0)
                .withArgs(addr1.address, ZERO_ADDRESS, burnAmount);

            expect(await t3Token.totalSupply()).to.equal(initialSupply - burnAmount);
            expect(await t3Token.balanceOf(addr1.address)).to.equal(initialBalance - burnAmount);
        });

        it("Should revert if user tries to burn zero amount", async function () {
            await expect(t3Token.connect(addr1).burn(0))
                .to.be.revertedWith("Burn amount must be positive");
        });

        it("Should revert if user tries to burn more than balance", async function () {
            const balance = await t3Token.balanceOf(addr1.address);
            await expect(t3Token.connect(addr1).burn(balance + 1n))
                .to.be.revertedWithCustomError(t3Token, "ERC20InsufficientBalance");
        });

        // --- burnFrom() ---
         it("Should allow authorized address (burner role or approved) to burnFrom another account", async function () {
            const initialSupply = await t3Token.totalSupply();
            const initialBalance = await t3Token.balanceOf(addr1.address);
            const initialAllowance = await t3Token.allowance(addr1.address, burner.address);

            expect(initialAllowance).to.be.gte(burnAmount);

            await expect(t3Token.connect(burner).burnFrom(addr1.address, burnAmount))
                .to.emit(t3Token, "Transfer")
                .withArgs(addr1.address, ZERO_ADDRESS, burnAmount);

            expect(await t3Token.totalSupply()).to.equal(initialSupply - burnAmount);
            expect(await t3Token.balanceOf(addr1.address)).to.equal(initialBalance - burnAmount);
            expect(await t3Token.allowance(addr1.address, burner.address)).to.equal(initialAllowance - burnAmount);
        });

         it("Should revert burnFrom if amount is zero", async function () {
             await expect(t3Token.connect(burner).burnFrom(addr1.address, 0))
                .to.be.revertedWith("Burn amount must be positive");
         });

         it("Should revert burnFrom if allowance is insufficient", async function () {
             await expect(t3Token.connect(burner).burnFrom(addr1.address, burnAmount + 1n))
                 .to.be.revertedWithCustomError(t3Token, "ERC20InsufficientAllowance");
         });

         it("Should revert burnFrom if account balance is insufficient", async function () {
             const balance = await t3Token.balanceOf(addr1.address);
             await t3Token.connect(addr1).approve(burner.address, balance + 1n); // Approve more than balance
             await expect(t3Token.connect(burner).burnFrom(addr1.address, balance + 1n))
                 .to.be.revertedWithCustomError(t3Token, "ERC20InsufficientBalance");
         });
    });

    // ========================================
    // Interbank Liability Ledger Tests
    // ========================================
    describe("Interbank Liability Ledger", function () {
        const liabilityAmount = toTokenAmount(100);
        const debtor = addr1; // Example: Bank A
        const creditor = addr2; // Example: Bank D

        it("Should allow ADMIN_ROLE to record liability", async function () {
            const initialLiability = await t3Token.interbankLiability(debtor.address, creditor.address);
            await expect(t3Token.connect(owner).recordInterbankLiability(debtor.address, creditor.address, liabilityAmount))
                .to.emit(t3Token, "InterbankLiabilityRecorded")
                .withArgs(debtor.address, creditor.address, liabilityAmount);
            expect(await t3Token.interbankLiability(debtor.address, creditor.address)).to.equal(initialLiability + liabilityAmount);
        });

        it("Should prevent non-ADMIN_ROLE from recording liability", async function () {
             await expect(t3Token.connect(nonOwner).recordInterbankLiability(debtor.address, creditor.address, liabilityAmount))
                .to.be.revertedWithCustomError(t3Token, "AccessControlUnauthorizedAccount")
                .withArgs(nonOwner.address, ADMIN_ROLE);
        });

        it("Should revert recording liability with zero amount or addresses", async function () {
            await expect(t3Token.connect(owner).recordInterbankLiability(ZERO_ADDRESS, creditor.address, liabilityAmount)).to.be.revertedWith("Debtor cannot be zero address");
            await expect(t3Token.connect(owner).recordInterbankLiability(debtor.address, ZERO_ADDRESS, liabilityAmount)).to.be.revertedWith("Creditor cannot be zero address");
            await expect(t3Token.connect(owner).recordInterbankLiability(debtor.address, debtor.address, liabilityAmount)).to.be.revertedWith("Debtor cannot be creditor");
            await expect(t3Token.connect(owner).recordInterbankLiability(debtor.address, creditor.address, 0)).to.be.revertedWith("Amount must be positive");
        });

        it("Should allow ADMIN_ROLE to clear liability", async function () {
            // Record liability first
            await t3Token.connect(owner).recordInterbankLiability(debtor.address, creditor.address, liabilityAmount);
            const recordedLiability = await t3Token.interbankLiability(debtor.address, creditor.address);
            expect(recordedLiability).to.equal(liabilityAmount);

            // Clear it
            const clearAmount = liabilityAmount / 2n;
             await expect(t3Token.connect(owner).clearInterbankLiability(debtor.address, creditor.address, clearAmount))
                .to.emit(t3Token, "InterbankLiabilityCleared")
                .withArgs(debtor.address, creditor.address, clearAmount);
            expect(await t3Token.interbankLiability(debtor.address, creditor.address)).to.equal(recordedLiability - clearAmount);

            // Clear remaining
             await expect(t3Token.connect(owner).clearInterbankLiability(debtor.address, creditor.address, recordedLiability - clearAmount))
                .to.not.be.reverted;
             expect(await t3Token.interbankLiability(debtor.address, creditor.address)).to.equal(0);
        });

         it("Should prevent non-ADMIN_ROLE from clearing liability", async function () {
             await t3Token.connect(owner).recordInterbankLiability(debtor.address, creditor.address, liabilityAmount);
             await expect(t3Token.connect(nonOwner).clearInterbankLiability(debtor.address, creditor.address, liabilityAmount))
                .to.be.revertedWithCustomError(t3Token, "AccessControlUnauthorizedAccount")
                .withArgs(nonOwner.address, ADMIN_ROLE);
        });

         it("Should revert clearing liability with zero amount or addresses", async function () {
            await expect(t3Token.connect(owner).clearInterbankLiability(ZERO_ADDRESS, creditor.address, liabilityAmount)).to.be.revertedWith("Debtor cannot be zero address");
            await expect(t3Token.connect(owner).clearInterbankLiability(debtor.address, ZERO_ADDRESS, liabilityAmount)).to.be.revertedWith("Creditor cannot be zero address");
            await expect(t3Token.connect(owner).clearInterbankLiability(debtor.address, debtor.address, liabilityAmount)).to.be.revertedWith("Debtor cannot be creditor");
            await expect(t3Token.connect(owner).clearInterbankLiability(debtor.address, creditor.address, 0)).to.be.revertedWith("Amount to clear must be positive");
        });

         it("Should revert clearing more liability than exists", async function () {
             await t3Token.connect(owner).recordInterbankLiability(debtor.address, creditor.address, liabilityAmount);
             await expect(t3Token.connect(owner).clearInterbankLiability(debtor.address, creditor.address, liabilityAmount + 1n))
                 .to.be.revertedWith("Amount to clear exceeds outstanding liability");
         });
    });

     // ========================================
    // Pausing Tests
    // ========================================
    describe("Pausable", function () {
        it("Should allow PAUSER_ROLE (owner) to pause and unpause", async function () {
            await expect(t3Token.connect(owner).pause()).to.not.be.reverted;
            expect(await t3Token.paused()).to.equal(true);
            await expect(t3Token.connect(owner).unpause()).to.not.be.reverted;
            expect(await t3Token.paused()).to.equal(false);
        });

        it("Should prevent non-PAUSER_ROLE from pausing", async function () {
             await expect(t3Token.connect(nonOwner).pause())
                .to.be.revertedWithCustomError(t3Token, "AccessControlUnauthorizedAccount")
                .withArgs(nonOwner.address, PAUSER_ROLE);
        });

         it("Should prevent non-PAUSER_ROLE from unpausing", async function () {
             await t3Token.connect(owner).pause(); // Pause first
             await expect(t3Token.connect(nonOwner).unpause())
                .to.be.revertedWithCustomError(t3Token, "AccessControlUnauthorizedAccount")
                .withArgs(nonOwner.address, PAUSER_ROLE);
        });

        it("Should prevent transfers when paused", async function () {
            await t3Token.connect(owner).pause();
            await expect(t3Token.connect(addr1).transfer(addr2.address, toTokenAmount(1)))
                .to.be.revertedWithCustomError(t3Token, "EnforcedPause");
        });

         it("Should prevent minting when paused", async function () {
             await t3Token.connect(owner).pause();
             await expect(t3Token.connect(minter).mint(addr1.address, toTokenAmount(1)))
                 .to.be.revertedWithCustomError(t3Token, "EnforcedPause");
         });

          it("Should prevent burning when paused", async function () {
             await t3Token.connect(owner).pause();
             await expect(t3Token.connect(addr1).burn(toTokenAmount(1)))
                 .to.be.revertedWithCustomError(t3Token, "EnforcedPause");
             await expect(t3Token.connect(burner).burnFrom(addr1.address, toTokenAmount(1)))
                 .to.be.revertedWithCustomError(t3Token, "EnforcedPause");
         });

         // Add checks for other pausable functions like reverseTransfer, checkHalfLifeExpiry
    });


    // ========================================
    // Existing Test Suites (Keep relevant parts)
    // ========================================
    describe("Owner Functions (Setters, Flagging)", function () { /* ... Keep relevant tests, ensure they use onlyRole(ADMIN_ROLE) ... */ });
    describe("ERC20 Standard Functions", function () { /* ... Keep relevant tests ... */ });
    describe("Basic Reverts and Requires", function () { /* ... Keep relevant tests ... */ });
    describe("Specific Branch Coverage (TODO)", function () { /* ... Keep TODO ... */ });

});
