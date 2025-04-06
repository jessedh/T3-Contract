const { ethers } = require("hardhat");
const fs = require("fs");
require("dotenv").config();

async function main() {
	const [deployer] = await ethers.getSigners();
	console.log(`🚀 Deploying T3Token with: ${deployer.address}`);

	/*
	  const name = "T3 Stablecoin";
	  const symbol = "T3";
	  const initialSupply = ethers.parseUnits("1000000", 18); // 1,000,000 T3
	  const initialOwner = deployer.address;
	*/

	const T3Token = await ethers.getContractFactory("T3Token");
	const t3 = await T3Token.deploy(deployer.address);
 /*
 const t3 = await T3Token.deploy(name, symbol, initialSupply, initialOwner);
 */ 
	await t3.waitForDeployment();

	const newAddress = await t3.getAddress();
	console.log(`✅ T3Token deployed at: ${newAddress}`);

	// Update .env file with new contract address
	const envPath = ".env";
	let envContent = fs.existsSync(envPath) ? fs.readFileSync(envPath, "utf8") : "";

	if (envContent.includes("T3_CONTRACT_ADDRESS=")) 
	{
		envContent = envContent.replace(/T3_CONTRACT_ADDRESS=.*/g, `T3_CONTRACT_ADDRESS=${newAddress}`);
	} else 
	{
		envContent += `\nT3_CONTRACT_ADDRESS=${newAddress}`;
	}

	fs.writeFileSync(envPath, envContent.trim());
		console.log("📝 Updated .env with new contract address");
	}

main().catch((error) => {
  console.error("❌ Deployment failed:", error);
  process.exitCode = 1;
});
