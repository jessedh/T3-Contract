const { ethers } = require("hardhat");
const fs = require("fs");
require("dotenv").config(); // Still useful if your Hardhat config uses keys from here

async function main() {
    // Get multiple signers from the Hardhat Network list
    const signers = await ethers.getSigners();

    // Use the first account as the deployer (standard practice)
    const deployer = signers[0];
    console.log(`🚀 Deploying T3Token with Deployer: ${deployer.address}`);

    // --- Use a specific Hardhat Network account as Treasury ---
    // Wallet 4 is usually at index 3 (0, 1, 2, 3)
    if (signers.length <= 3) {
        throw new Error("❌ Not enough default accounts available in Hardhat Network to use index 3 (wallet 4).");
    }
    const treasurySigner = signers[3];
    const treasuryAddress = treasurySigner.address;
    console.log(`💰 Using Treasury Address (Wallet 4): ${treasuryAddress}`);
    // --- End Treasury Address Logic ---


    const ContractName = "T3Token";
    const T3Token = await ethers.getContractFactory(ContractName);

    // Deploy with TWO arguments: initialOwner (deployer) and the chosen treasuryAddress
    console.log(
        `Deploying ${ContractName} with initialOwner=${deployer.address} and treasury=${treasuryAddress}...`
    );
    // Use the deployer signer object to send the transaction
    const t3 = await T3Token.connect(deployer).deploy(deployer.address, treasuryAddress); // Pass both args

    await t3.waitForDeployment();

    const newAddress = await t3.getAddress();
    console.log(`✅ ${ContractName} deployed at: ${newAddress}`);

    // ... (rest of the .env update logic remains the same) ...
        // Update .env file with new contract address
    const envPath = ".env";
    let envContent = fs.existsSync(envPath) ? fs.readFileSync(envPath, "utf8") : "";

    const envVarName = "T3_CONTRACT_ADDRESS"; // Define the env var name
    const newEntry = `${envVarName}=${newAddress}`;

    // Use a regex to replace the line if it exists, otherwise append
    const regex = new RegExp(`^${envVarName}=.*$`, "gm");
    if (envContent.match(regex)) {
        envContent = envContent.replace(regex, newEntry);
        console.log(`📝 Replaced ${envVarName} in .env file.`);
    } else {
         // Ensure there's a newline if adding to existing non-empty content
        if (envContent.length > 0 && !envContent.endsWith('\n')) {
            envContent += '\n';
        }
        envContent += newEntry;
        console.log(`📝 Added ${envVarName} to .env file.`);
    }

    // Write the updated content back, trimming only surrounding whitespace
    fs.writeFileSync(envPath, envContent.trim());
    console.log(`📝 .env file updated successfully.`);
}

main().catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exitCode = 1;
});