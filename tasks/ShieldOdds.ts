import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

task("shieldodds:createMarket")
  .addParam("question", "The prediction question")
  .addParam("deadline", "Unix timestamp for betting deadline")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const tx = await contract.createMarket(taskArguments.question, taskArguments.deadline);
    const receipt = await tx.wait();

    // Parse MarketCreated event
    const event = receipt?.logs
      .map((log: any) => {
        try {
          return contract.interface.parseLog({ topics: [...log.topics], data: log.data });
        } catch {
          return null;
        }
      })
      .find((e: any) => e?.name === "MarketCreated");

    if (event) {
      console.log(`✅ Market created!`);
      console.log(`   Market ID: ${event.args.marketId}`);
      console.log(`   Question: ${event.args.question}`);
      console.log(`   Deadline: ${new Date(Number(event.args.deadline) * 1000).toISOString()}`);
      console.log(`   Creator: ${event.args.creator}`);
    }
  });

task("shieldodds:getMarket")
  .addParam("id", "Market ID")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const market = await contract.getMarket(taskArguments.id);
    const statusNames = ["Open", "Resolved", "Settled", "Cancelled"];

    console.log(`\n📊 Market #${taskArguments.id}`);
    console.log(`   Question: ${market.question}`);
    console.log(`   Creator: ${market.creator}`);
    console.log(`   Deadline: ${new Date(Number(market.deadline) * 1000).toISOString()}`);
    console.log(`   Status: ${statusNames[Number(market.status)]}`);
    console.log(`   Outcome: ${Number(market.status) >= 1 ? (market.outcome === 1n ? "YES" : "NO") : "Pending"}`);
    console.log(`   Total Pool: ${ethers.formatEther(market.totalPool)} ETH`);
    console.log(`   Winning Pool: ${ethers.formatEther(market.totalWinningPool)} ETH`);
    console.log(`   Bet Count: ${market.betCount}`);
  });

task("shieldodds:resolve")
  .addParam("id", "Market ID")
  .addParam("outcome", "Outcome: 0=NO, 1=YES")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const tx = await contract.resolve(taskArguments.id, taskArguments.outcome);
    await tx.wait();

    console.log(`✅ Market #${taskArguments.id} resolved with outcome: ${taskArguments.outcome === "1" ? "YES" : "NO"}`);
  });

task("shieldodds:getHandles")
  .addParam("id", "Market ID")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const handles = await contract.getMarketHandles(taskArguments.id);
    console.log(`\n🔐 Encrypted handles for Market #${taskArguments.id}:`);
    handles.forEach((h: string, i: number) => {
      console.log(`   Bet #${i}: ${h}`);
    });
  });

task("shieldodds:info").setAction(async function (_taskArguments: TaskArguments, hre) {
  const { deployments } = hre;
  const { ShieldOdds: deployment } = await deployments.all();
  console.log(`\n🛡️  ShieldOdds Contract`);
  console.log(`   Address: ${deployment.address}`);
  console.log(`   Network: ${hre.network.name}`);
});
