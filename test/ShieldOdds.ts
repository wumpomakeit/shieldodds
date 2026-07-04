import { expect } from "chai";
import { ethers } from "hardhat";

describe("ShieldOdds", function () {
  async function deployFixture() {
    const [owner, creator, bettor1, bettor2] = await ethers.getSigners();
    const ShieldOdds = await ethers.getContractFactory("ShieldOdds");
    const contract = await ShieldOdds.deploy();
    await contract.waitForDeployment();
    return { contract, owner, creator, bettor1, bettor2 };
  }

  describe("Deployment", function () {
    it("should set the deployer as owner", async function () {
      const { contract, owner } = await deployFixture();
      expect(await contract.owner()).to.equal(owner.address);
    });

    it("should start with zero markets", async function () {
      const { contract } = await deployFixture();
      expect(await contract.marketCount()).to.equal(0);
    });
  });

  describe("createMarket", function () {
    it("should create a market with correct parameters", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      await expect(contract.connect(creator).createMarket("Will ETH hit $10k?", deadline))
        .to.emit(contract, "MarketCreated")
        .withArgs(0, "Will ETH hit $10k?", deadline, creator.address);

      expect(await contract.marketCount()).to.equal(1);
    });

    it("should revert if deadline is in the past", async function () {
      const { contract, creator } = await deployFixture();
      const pastDeadline = Math.floor(Date.now() / 1000) - 3600;

      await expect(
        contract.connect(creator).createMarket("Old question?", pastDeadline),
      ).to.be.revertedWithCustomError(contract, "DeadlineMustBeInFuture");
    });
  });

  describe("cancelMarket", function () {
    it("should allow creator to cancel an open market", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      await contract.connect(creator).createMarket("Cancel me?", deadline);

      await expect(contract.connect(creator).cancelMarket(0)).to.emit(contract, "MarketCancelled").withArgs(0);
    });
  });

  // Note: FHE-specific tests (placeBet, settle) require the fhEVM mock environment.
  // Run with `npx hardhat test` (local hardhat chain with mock) or
  // `npx hardhat test --network sepolia` for live tests.
});
