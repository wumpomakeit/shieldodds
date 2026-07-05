import { task } from "hardhat/config";
import type { TaskArguments } from "hardhat/types";

task("shieldodds:createMarket")
  .addParam("question", "The prediction question")
  .addParam("deadline", "Unix timestamp for betting deadline")
  .addOptionalParam("pricefeed", "Chainlink price feed address (omit for manual market)", "0x0000000000000000000000000000000000000000")
  .addOptionalParam("targetprice", "Target price in feed decimals (e.g. 10000000000000 for $100k with 8 decimals)", "0")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const tx = await contract.createMarket(
      taskArguments.question,
      taskArguments.deadline,
      taskArguments.pricefeed,
      taskArguments.targetprice
    );
    const receipt = await tx.wait();

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
      const isOracle = event.args.priceFeed !== "0x0000000000000000000000000000000000000000";
      console.log(`✅ Market created!`);
      console.log(`   Market ID: ${event.args.marketId}`);
      console.log(`   Question: ${event.args.question}`);
      console.log(`   Deadline: ${new Date(Number(event.args.deadline) * 1000).toISOString()}`);
      console.log(`   Creator: ${event.args.creator}`);
      console.log(`   Type: ${isOracle ? "Oracle (Chainlink)" : "Manual"}`);
      if (isOracle) {
        console.log(`   Price Feed: ${event.args.priceFeed}`);
        console.log(`   Target Price: ${event.args.targetPrice}`);
      }
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
    const isOracle = market.priceFeed !== "0x0000000000000000000000000000000000000000";

    console.log(`\n📊 Market #${taskArguments.id}`);
    console.log(`   Question: ${market.question}`);
    console.log(`   Creator: ${market.creator}`);
    console.log(`   Deadline: ${new Date(Number(market.deadline) * 1000).toISOString()}`);
    console.log(`   Status: ${statusNames[Number(market.status)]}`);
    console.log(`   Outcome: ${Number(market.status) >= 1 ? (market.outcome === 1n ? "YES" : "NO") : "Pending"}`);
    console.log(`   Bet Count: ${market.betCount}`);
    console.log(`   Type: ${isOracle ? "Oracle (Chainlink)" : "Manual"}`);
    if (isOracle) {
      console.log(`   Price Feed: ${market.priceFeed}`);
      console.log(`   Target Price: ${market.targetPrice}`);
      console.log(`   Resolved Price: ${market.resolvedPrice}`);
    }
  });

task("shieldodds:resolve")
  .addParam("id", "Market ID")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    // Oracle markets use resolve(), manual markets need resolveManual()
    const market = await contract.getMarket(taskArguments.id);
    const isOracle = market.priceFeed !== "0x0000000000000000000000000000000000000000";

    if (isOracle) {
      const tx = await contract.resolve(taskArguments.id);
      await tx.wait();
      const updated = await contract.getMarket(taskArguments.id);
      console.log(`✅ Market #${taskArguments.id} resolved via Chainlink oracle`);
      console.log(`   Resolved Price: ${updated.resolvedPrice}`);
      console.log(`   Outcome: ${updated.outcome === 1n ? "YES" : "NO"}`);
    } else {
      console.log(`❌ Market #${taskArguments.id} is manual — use shieldodds:resolveManual`);
    }
  });

task("shieldodds:resolveManual")
  .addParam("id", "Market ID")
  .addParam("outcome", "Outcome: 0=NO, 1=YES")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const tx = await contract.resolveManual(taskArguments.id, taskArguments.outcome);
    await tx.wait();

    console.log(`✅ Market #${taskArguments.id} manually resolved: ${taskArguments.outcome === "1" ? "YES" : "NO"}`);
  });

task("shieldodds:getPrice")
  .addParam("id", "Market ID")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const [price, decimals, updatedAt] = await contract.getLatestPrice(taskArguments.id);
    const priceFloat = Number(price) / 10 ** Number(decimals);

    console.log(`\n💰 Live Price for Market #${taskArguments.id}`);
    console.log(`   Price: $${priceFloat.toFixed(2)}`);
    console.log(`   Raw: ${price} (${decimals} decimals)`);
    console.log(`   Updated: ${new Date(Number(updatedAt) * 1000).toISOString()}`);
  });

task("shieldodds:getHandles")
  .addParam("id", "Market ID")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const handles = await contract.getMarketHandles(taskArguments.id);
    console.log(`\n🔐 Encrypted bet amount handles for Market #${taskArguments.id}:`);
    handles.forEach((h: string, i: number) => {
      console.log(`   Bet #${i}: ${h}`);
    });
  });

task("shieldodds:deposit")
  .addParam("amount", "ETH amount to deposit (e.g. '0.1')")
  .setAction(async function (taskArguments: TaskArguments, hre) {
    const { ethers, deployments } = hre;
    const { ShieldOdds: deployment } = await deployments.all();
    const contract = await ethers.getContractAt("ShieldOdds", deployment.address);

    const value = ethers.parseEther(taskArguments.amount);
    const tx = await contract.deposit({ value });
    await tx.wait();

    console.log(`✅ Deposited ${taskArguments.amount} ETH into encrypted balance`);
  });

task("shieldodds:info").setAction(async function (_taskArguments: TaskArguments, hre) {
  const { deployments } = hre;
  const { ShieldOdds: deployment } = await deployments.all();
  console.log(`\n🛡️  ShieldOdds Contract`);
  console.log(`   Address: ${deployment.address}`);
  console.log(`   Network: ${hre.network.name}`);
});
