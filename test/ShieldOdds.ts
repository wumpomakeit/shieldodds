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

    it("should start with zero withdrawal requests", async function () {
      const { contract } = await deployFixture();
      expect(await contract.withdrawalCount()).to.equal(0);
    });
  });

  describe("deposit", function () {
    it("should accept ETH deposits", async function () {
      const { contract, bettor1 } = await deployFixture();
      const depositAmount = ethers.parseEther("1.0");

      await expect(contract.connect(bettor1).deposit({ value: depositAmount }))
        .to.emit(contract, "Deposited")
        .withArgs(bettor1.address, depositAmount);
    });

    it("should revert on zero deposit", async function () {
      const { contract, bettor1 } = await deployFixture();
      await expect(
        contract.connect(bettor1).deposit({ value: 0 }),
      ).to.be.revertedWithCustomError(contract, "ZeroDeposit");
    });

    it("should return a non-zero balance handle after deposit", async function () {
      const { contract, bettor1 } = await deployFixture();
      await contract.connect(bettor1).deposit({ value: ethers.parseEther("0.5") });

      const handle = await contract.getBalanceHandle(bettor1.address);
      expect(handle).to.not.equal(ethers.ZeroHash);
    });

    it("should accumulate multiple deposits", async function () {
      const { contract, bettor1 } = await deployFixture();
      await contract.connect(bettor1).deposit({ value: ethers.parseEther("0.5") });
      await contract.connect(bettor1).deposit({ value: ethers.parseEther("0.3") });

      // After two deposits, balance handle should still be non-zero
      const handle = await contract.getBalanceHandle(bettor1.address);
      expect(handle).to.not.equal(ethers.ZeroHash);
    });
  });

  describe("createMarket", function () {
    it("should create a market with correct parameters", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = Math.floor(Date.now() / 1000) + 3600;

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

    it("should return correct market details via getMarket", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      await contract.connect(creator).createMarket("Test?", deadline);

      const market = await contract.getMarket(0);
      expect(market.question).to.equal("Test?");
      expect(market.creator).to.equal(creator.address);
      expect(market.deadline).to.equal(deadline);
      expect(market.status).to.equal(0); // Open
      expect(market.betCount).to.equal(0);
    });
  });

  describe("cancelMarket", function () {
    it("should allow creator to cancel an open market", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      await contract.connect(creator).createMarket("Cancel me?", deadline);

      await expect(contract.connect(creator).cancelMarket(0))
        .to.emit(contract, "MarketCancelled")
        .withArgs(0);
    });

    it("should allow owner to cancel any market", async function () {
      const { contract, owner, creator } = await deployFixture();
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      await contract.connect(creator).createMarket("Owner cancel?", deadline);

      await expect(contract.connect(owner).cancelMarket(0))
        .to.emit(contract, "MarketCancelled")
        .withArgs(0);
    });

    it("should revert if non-creator/non-owner tries to cancel", async function () {
      const { contract, creator, bettor1 } = await deployFixture();
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      await contract.connect(creator).createMarket("No cancel?", deadline);

      await expect(
        contract.connect(bettor1).cancelMarket(0),
      ).to.be.revertedWithCustomError(contract, "OnlyCreator");
    });
  });

  describe("Admin", function () {
    it("should allow owner to transfer ownership", async function () {
      const { contract, owner, creator } = await deployFixture();
      await contract.connect(owner).transferOwnership(creator.address);
      expect(await contract.owner()).to.equal(creator.address);
    });

    it("should revert transferOwnership from non-owner", async function () {
      const { contract, bettor1, creator } = await deployFixture();
      let reverted = false;
      try {
        const tx = await contract.connect(bettor1).transferOwnership(creator.address);
        await tx.wait();
      } catch {
        reverted = true;
      }
      expect(reverted).to.be.true;
    });

    it("should revert withdrawFees when no fees accumulated", async function () {
      const { contract, owner } = await deployFixture();
      await expect(
        contract.connect(owner).withdrawFees(),
      ).to.be.revertedWithCustomError(contract, "NothingToWithdraw");
    });
  });

  // Note: FHE-specific tests (placeBet, settle, requestWithdrawal, completeWithdrawal)
  // require the fhEVM mock environment for encrypted operations.
  // Run with `npx hardhat test` (local hardhat chain with FHE mock) or
  // test on Sepolia for live FHE integration.
  //
  // Key flows to test on live network:
  // 1. deposit → placeBet (encrypted amount) → resolve → settle → withdraw
  // 2. deposit → requestWithdrawal → completeWithdrawal
  // 3. deposit → placeBet → cancelMarket (encrypted amounts returned to balance)
});
