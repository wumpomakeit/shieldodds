import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  console.log("Deploying ShieldOdds with account:", deployer);

  const deployed = await deploy("ShieldOdds", {
    from: deployer,
    log: true,
  });

  console.log(`✅ ShieldOdds deployed at: ${deployed.address}`);
  console.log(`   Network: ${hre.network.name}`);
  console.log(`   Chain ID: ${hre.network.config.chainId}`);
};

export default func;
func.id = "deploy_shieldOdds";
func.tags = ["ShieldOdds"];
