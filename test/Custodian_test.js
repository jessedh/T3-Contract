// test/CustodianRegistry.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("CustodianRegistry Contract", function () {
    // --- Constants ---
    const ZERO_ADDRESS = ethers.ZeroAddress;

    // --- Roles ---
    let ADMIN_ROLE;
    let CUSTODIAN_ROLE;
    let DEFAULT_ADMIN_ROLE;

    // --- Fixture ---
    async function deployCustodianRegistryFixture() {
        // Get signers
        const [deployer, admin, custodian1, custodian2, user1, user2, nonAdminOrCustodian] = await ethers.getSigners();

        // Deploy the contract
        const CustodianRegistry = await ethers.getContractFactory("CustodianRegistry");
        const registry = await CustodianRegistry.deploy(admin.address); // Admin gets ADMIN_ROLE

        // Get role hashes
        ADMIN_ROLE = await registry.ADMIN_ROLE();
        CUSTODIAN_ROLE = await registry.CUSTODIAN_ROLE();
        DEFAULT_ADMIN_ROLE = await registry.DEFAULT_ADMIN_ROLE();

        // Grant initial roles needed for tests
        await registry.connect(admin).grantRole(CUSTODIAN_ROLE, custodian1.address);
        await registry.connect(admin).grantRole(CUSTODIAN_ROLE, custodian2.address);

        return { registry, deployer, admin, custodian1, custodian2, user1, user2, nonAdminOrCustodian };
    }

    // --- Test Suites ---
    let registry, deployer, admin, custodian1, custodian2, user1, user2, nonAdminOrCustodian;

    beforeEach(async function () {
        // Load the fixture before each test
        ({ registry, deployer, admin, custodian1, custodian2, user1, user2, nonAdminOrCustodian } = await loadFixture(deployCustodianRegistryFixture));
    });

    describe("Deployment & Role Setup", function () {
        it("Should set the correct admin roles", async function () {
            expect(await registry.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
            expect(await registry.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
        });

        it("Should have granted CUSTODIAN_ROLE correctly in fixture", async function () {
            expect(await registry.hasRole(CUSTODIAN_ROLE, custodian1.address)).to.be.true;
            expect(await registry.hasRole(CUSTODIAN_ROLE, custodian2.address)).to.be.true;
        });
    });

    describe("Access Control", function () {
        it("Should allow ADMIN_ROLE to grant CUSTODIAN_ROLE", async function () {
            await registry.connect(admin).grantRole(CUSTODIAN_ROLE, nonAdminOrCustodian.address);
            expect(await registry.hasRole(CUSTODIAN_ROLE, nonAdminOrCustodian.address)).to.be.true;
        });

        it("Should prevent non-ADMIN_ROLE from granting CUSTODIAN_ROLE", async function () {
            await expect(registry.connect(nonAdminOrCustodian).grantRole(CUSTODIAN_ROLE, user1.address))
                .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
                .withArgs(nonAdminOrCustodian.address, DEFAULT_ADMIN_ROLE); // Granting requires Default Admin
        });

        it("Should allow ADMIN_ROLE to revoke CUSTODIAN_ROLE", async function () {
            await registry.connect(admin).revokeRole(CUSTODIAN_ROLE, custodian1.address);
            expect(await registry.hasRole(CUSTODIAN_ROLE, custodian1.address)).to.be.false;
        });

        it("Should prevent non-ADMIN_ROLE from revoking CUSTODIAN_ROLE", async function () {
             await expect(registry.connect(nonAdminOrCustodian).revokeRole(CUSTODIAN_ROLE, custodian1.address))
                .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
                .withArgs(nonAdminOrCustodian.address, DEFAULT_ADMIN_ROLE);
        });

        it("Should allow CUSTODIAN_ROLE holder to renounce their role", async function () {
            await registry.connect(custodian1).renounceRole(CUSTODIAN_ROLE, custodian1.address);
            expect(await registry.hasRole(CUSTODIAN_ROLE, custodian1.address)).to.be.false;
        });
    });

    describe("Wallet Registration (`registerCustodiedWallet`)", function () {
        let kycValidTs, kycExpiresTs;

        beforeEach(async function() {
            kycValidTs = await time.latest();
            kycExpiresTs = kycValidTs + (365 * 24 * 60 * 60); // Valid for 1 year
        });

        it("Should allow CUSTODIAN_ROLE to register a wallet", async function () {
            await expect(registry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidTs, kycExpiresTs))
                .to.emit(registry, "WalletRegistered")
                .withArgs(user1.address, custodian1.address, kycValidTs, kycExpiresTs);

            const data = await registry.getKYCTimestamps(user1.address);
            expect(await registry.getCustodian(user1.address)).to.equal(custodian1.address);
            expect(data.validatedTimestamp).to.equal(kycValidTs);
            expect(data.expiresTimestamp).to.equal(kycExpiresTs);
        });

        it("Should allow registration with zero expiry timestamp", async function () {
             await expect(registry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidTs, 0))
                .to.emit(registry, "WalletRegistered")
                .withArgs(user1.address, custodian1.address, kycValidTs, 0);
             const data = await registry.getKYCTimestamps(user1.address);
             expect(data.expiresTimestamp).to.equal(0);
        });

        it("Should prevent non-CUSTODIAN_ROLE from registering", async function () {
            await expect(registry.connect(nonAdminOrCustodian).registerCustodiedWallet(user1.address, kycValidTs, kycExpiresTs))
                .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
                .withArgs(nonAdminOrCustodian.address, CUSTODIAN_ROLE);
        });

        it("Should revert registering zero address", async function () {
            await expect(registry.connect(custodian1).registerCustodiedWallet(ZERO_ADDRESS, kycValidTs, kycExpiresTs))
                .to.be.revertedWith("User address cannot be zero");
        });

        it("Should revert if expiry is before validation", async function () {
             await expect(registry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidTs, kycValidTs - 1))
                .to.be.revertedWith("KYC expiry before validation");
        });

        it("Should allow custodian to re-register (update) a wallet they manage", async function () {
             await registry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidTs, kycExpiresTs);
             const newValidTs = await time.latest() + 10;
             const newExpireTs = newValidTs + (365 * 24 * 60 * 60);
             await expect(registry.connect(custodian1).registerCustodiedWallet(user1.address, newValidTs, newExpireTs))
                .to.emit(registry, "WalletRegistered") // Should emit again
                .withArgs(user1.address, custodian1.address, newValidTs, newExpireTs);

             const data = await registry.getKYCTimestamps(user1.address);
             expect(data.validatedTimestamp).to.equal(newValidTs);
             expect(data.expiresTimestamp).to.equal(newExpireTs);
        });

        it("Should allow a different custodian to register a wallet previously registered by another (overwrite)", async function () {
             // Current logic allows overwrite, test this behavior
             await registry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidTs, kycExpiresTs);
             expect(await registry.getCustodian(user1.address)).to.equal(custodian1.address);

             const newValidTs = await time.latest() + 10;
             await expect(registry.connect(custodian2).registerCustodiedWallet(user1.address, newValidTs, 0))
                 .to.emit(registry, "WalletRegistered")
                 .withArgs(user1.address, custodian2.address, newValidTs, 0);

             expect(await registry.getCustodian(user1.address)).to.equal(custodian2.address); // Custodian updated
        });
    });

    describe("KYC Status Update (`updateKYCStatus`)", function () {
        let kycValidTs, kycExpiresTs;

        beforeEach(async function() {
            kycValidTs = await time.latest();
            kycExpiresTs = kycValidTs + (365 * 24 * 60 * 60);
            await registry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidTs, kycExpiresTs);
        });

        it("Should allow the registered custodian to update KYC status", async function() {
            const newValidTs = await time.latest() + 20;
            const newExpireTs = newValidTs + (180 * 24 * 60 * 60); // 6 months validity

            await expect(registry.connect(custodian1).updateKYCStatus(user1.address, newValidTs, newExpireTs))
                .to.emit(registry, "KYCStatusUpdated")
                .withArgs(user1.address, custodian1.address, newValidTs, newExpireTs);

            const data = await registry.getKYCTimestamps(user1.address);
            expect(data.validatedTimestamp).to.equal(newValidTs);
            expect(data.expiresTimestamp).to.equal(newExpireTs);
        });

        it("Should prevent a different custodian from updating KYC status", async function() {
            const newValidTs = await time.latest() + 20;
            await expect(registry.connect(custodian2).updateKYCStatus(user1.address, newValidTs, 0))
                .to.be.revertedWith("Caller is not the registered custodian");
        });

        it("Should prevent non-custodian from updating KYC status", async function() {
             const newValidTs = await time.latest() + 20;
             await expect(registry.connect(nonAdminOrCustodian).updateKYCStatus(user1.address, newValidTs, 0))
                 .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
                 .withArgs(nonAdminOrCustodian.address, CUSTODIAN_ROLE);
        });

        it("Should revert updating KYC for an unregistered wallet", async function() {
            const newValidTs = await time.latest() + 20;
            await expect(registry.connect(custodian1).updateKYCStatus(user2.address, newValidTs, 0)) // user2 is not registered
                .to.be.revertedWith("Caller is not the registered custodian");
        });

         it("Should revert updating KYC if expiry is before validation", async function() {
            const newValidTs = await time.latest() + 20;
            await expect(registry.connect(custodian1).updateKYCStatus(user1.address, newValidTs, newValidTs - 1))
                .to.be.revertedWith("KYC expiry before validation");
        });
    });

    describe("Wallet Unregistering (`unregisterCustodiedWallet`)", function () {
         let kycValidTs, kycExpiresTs;

        beforeEach(async function() {
            kycValidTs = await time.latest();
            kycExpiresTs = kycValidTs + (365 * 24 * 60 * 60);
            await registry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidTs, kycExpiresTs);
        });

        it("Should allow the registered custodian to unregister a wallet", async function() {
            await expect(registry.connect(custodian1).unregisterCustodiedWallet(user1.address))
                .to.emit(registry, "WalletUnregistered")
                .withArgs(user1.address, custodian1.address);

            expect(await registry.getCustodian(user1.address)).to.equal(ZERO_ADDRESS);
            const data = await registry.getKYCTimestamps(user1.address);
            expect(data.validatedTimestamp).to.equal(0);
            expect(data.expiresTimestamp).to.equal(0);
        });

         it("Should prevent a different custodian from unregistering", async function() {
            await expect(registry.connect(custodian2).unregisterCustodiedWallet(user1.address))
                .to.be.revertedWith("Caller is not the registered custodian");
        });

        it("Should prevent non-custodian from unregistering", async function() {
             await expect(registry.connect(nonAdminOrCustodian).unregisterCustodiedWallet(user1.address))
                 .to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount")
                 .withArgs(nonAdminOrCustodian.address, CUSTODIAN_ROLE);
        });

        it("Should revert unregistering an already unregistered wallet", async function() {
            await registry.connect(custodian1).unregisterCustodiedWallet(user1.address); // Unregister first
            await expect(registry.connect(custodian1).unregisterCustodiedWallet(user1.address)) // Try again
                .to.be.revertedWith("Caller is not the registered custodian"); // Fails because custodian is now address(0)
        });
         it("Should revert unregistering zero address", async function() {
            await expect(registry.connect(custodian1).unregisterCustodiedWallet(ZERO_ADDRESS))
                .to.be.revertedWith("User address cannot be zero");
        });
    });

     describe("View Functions", function () {
        let kycValidTs, kycExpiresTs;

        beforeEach(async function() {
            kycValidTs = await time.latest();
            kycExpiresTs = kycValidTs + (365 * 24 * 60 * 60);
            await registry.connect(custodian1).registerCustodiedWallet(user1.address, kycValidTs, kycExpiresTs);
            // Register another wallet with no expiry
            await registry.connect(custodian2).registerCustodiedWallet(user2.address, kycValidTs, 0);
        });

        it("getCustodian: Should return correct custodian or zero address", async function() {
            expect(await registry.getCustodian(user1.address)).to.equal(custodian1.address);
            expect(await registry.getCustodian(user2.address)).to.equal(custodian2.address);
            expect(await registry.getCustodian(nonAdminOrCustodian.address)).to.equal(ZERO_ADDRESS); // Unregistered
        });

        it("getKYCTimestamps: Should return correct timestamps or zeros", async function() {
            const data1 = await registry.getKYCTimestamps(user1.address);
            expect(data1.validatedTimestamp).to.equal(kycValidTs);
            expect(data1.expiresTimestamp).to.equal(kycExpiresTs);

            const data2 = await registry.getKYCTimestamps(user2.address);
            expect(data2.validatedTimestamp).to.equal(kycValidTs);
            expect(data2.expiresTimestamp).to.equal(0);

            const data3 = await registry.getKYCTimestamps(nonAdminOrCustodian.address);
            expect(data3.validatedTimestamp).to.equal(0);
            expect(data3.expiresTimestamp).to.equal(0);
        });

        it("isKYCValid: Should return correct validity status", async function() {
            // Test case 1: Valid KYC with future expiry
            expect(await registry.isKYCValid(user1.address)).to.be.true;

            // Test case 2: Valid KYC with no expiry
            expect(await registry.isKYCValid(user2.address)).to.be.true;

            // Test case 3: Expired KYC
            await time.setNextBlockTimestamp(kycExpiresTs + 1); // Advance time past expiry for user1
            expect(await registry.isKYCValid(user1.address)).to.be.false;
            expect(await registry.isKYCValid(user2.address)).to.be.true; // user2 still valid (no expiry)

             // Test case 4: Unregistered user
             expect(await registry.isKYCValid(nonAdminOrCustodian.address)).to.be.false;

             // Test case 5: Registered but KYC validation timestamp is 0
              await registry.connect(custodian1).registerCustodiedWallet(addrs[0].address, 0, 0);
              expect(await registry.isKYCValid(addrs[0].address)).to.be.false;
        });
    });

    describe("Custodian Tracking (Optional)", function () {
        it("custodianCount: Should track count correctly", async function() {
            expect(await registry.custodianCount()).to.equal(2); // custodian1, custodian2 from fixture
            await registry.connect(admin).grantRole(CUSTODIAN_ROLE, addrs[0].address);
            expect(await registry.custodianCount()).to.equal(3);
            await registry.connect(admin).revokeRole(CUSTODIAN_ROLE, custodian1.address);
            expect(await registry.custodianCount()).to.equal(2);
            await registry.connect(admin).revokeRole(CUSTODIAN_ROLE, addrs[0].address);
            expect(await registry.custodianCount()).to.equal(1);
             await registry.connect(admin).revokeRole(CUSTODIAN_ROLE, custodian2.address);
            expect(await registry.custodianCount()).to.equal(0);
        });

         it("custodianAtIndex: Should return correct address or revert", async function() {
             const c1 = custodian1.address;
             const c2 = custodian2.address;
             const count = await registry.custodianCount(); // Should be 2
             expect(count).to.equal(2);

             const retrieved = [await registry.custodianAtIndex(0), await registry.custodianAtIndex(1)];
             expect(retrieved).to.contain.members([c1, c2]); // Check both are present, order might vary

             await expect(registry.custodianAtIndex(2)).to.be.reverted; // Out of bounds
         });
    });

});
