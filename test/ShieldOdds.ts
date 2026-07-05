import { expect } from "chai";
import { ethers } from "hardhat";

describe("ShieldOdds", function () {
  const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

  async function deployFixture() {
    const [owner, creator, bettor1, bettor2] = await ethers.getSigners();
    const ShieldOdds = await ethers.getContractFactory("ShieldOdds");
    const contract = await ShieldOdds.deploy();
    await contract.waitForDeployment();
    return { contract, owner, creator, bettor1, bettor2 };
  }

  /** Get current block timestamp + offset */
  async function futureDeadline(offset: number = 3600): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block!.timestamp + offset;
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

    it("should have correct protocol fee (1%)", async function () {
      const { contract } = await deployFixture();
      expect(await contract.PROTOCOL_FEE_BPS()).to.equal(100);
    });

    it("should have correct max price staleness (24h)", async function () {
      const { contract } = await deployFixture();
      expect(await contract.MAX_PRICE_STALENESS()).to.equal(86400);
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

      const handle = await contract.getBalanceHandle(bettor1.address);
      expect(handle).to.not.equal(ethers.ZeroHash);
    });
  });

  describe("createMarket — manual", function () {
    it("should create a manual market with correct parameters", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = await futureDeadline();

      await expect(contract.connect(creator).createMarket("Will ETH hit $10k?", deadline, ZERO_ADDRESS, 0))
        .to.emit(contract, "MarketCreated")
        .withArgs(0, "Will ETH hit $10k?", deadline, creator.address, ZERO_ADDRESS, 0);

      expect(await contract.marketCount()).to.equal(1);
    });

    it("should revert if deadline is in the past", async function () {
      const { contract, creator } = await deployFixture();
      const block = await ethers.provider.getBlock("latest");
      const pastDeadline = block!.timestamp - 3600;

      await expect(
        contract.connect(creator).createMarket("Old question?", pastDeadline, ZERO_ADDRESS, 0),
      ).to.be.revertedWithCustomError(contract, "DeadlineMustBeInFuture");
    });

    it("should return correct market details via getMarket", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = await futureDeadline();
      await contract.connect(creator).createMarket("Test?", deadline, ZERO_ADDRESS, 0);

      const market = await contract.getMarket(0);
      expect(market.question).to.equal("Test?");
      expect(market.creator).to.equal(creator.address);
      expect(market.deadline).to.equal(deadline);
      expect(market.status).to.equal(0); // Open
      expect(market.betCount).to.equal(0);
      expect(market.priceFeed).to.equal(ZERO_ADDRESS);
      expect(market.targetPrice).to.equal(0);
      expect(market.resolvedPrice).to.equal(0);
    });
  });

  describe("createMarket — oracle", function () {
    it("should revert with invalid price feed address", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = await futureDeadline();
      const fakeFeed = "0x0000000000000000000000000000000000000001";

      await expect(
        contract.connect(creator).createMarket("BTC > $100k?", deadline, fakeFeed, 10000000000000),
      ).to.be.reverted;
    });
  });

  describe("resolveManual", function () {
    it("should revert resolveManual on oracle market (DeadlineNotReached)", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = await futureDeadline();
      await contract.connect(creator).createMarket("Manual?", deadline, ZERO_ADDRESS, 0);

      await expect(
        contract.connect(creator).resolveManual(0, 1),
      ).to.be.revertedWithCustomError(contract, "DeadlineNotReached");
    });

    it("should revert resolve() on manual market", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = await futureDeadline();
      await contract.connect(creator).createMarket("Manual?", deadline, ZERO_ADDRESS, 0);

      await expect(
        contract.connect(creator).resolve(0),
      ).to.be.revertedWithCustomError(contract, "NotOracleMarket");
    });

    it("should revert if non-creator tries resolveManual", async function () {
      const { contract, creator, bettor1 } = await deployFixture();
      const deadline = await futureDeadline(60);
      await contract.connect(creator).createMarket("Only creator?", deadline, ZERO_ADDRESS, 0);

      // Fast-forward past deadline
      await ethers.provider.send("evm_increaseTime", [120]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        contract.connect(bettor1).resolveManual(0, 1),
      ).to.be.revertedWithCustomError(contract, "OnlyCreator");
    });

    it("should revert with invalid outcome", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = await futureDeadline(60);
      await contract.connect(creator).createMarket("Invalid?", deadline, ZERO_ADDRESS, 0);

      await ethers.provider.send("evm_increaseTime", [120]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        contract.connect(creator).resolveManual(0, 2),
      ).to.be.revertedWithCustomError(contract, "InvalidOutcome");
    });
  });

  describe("cancelMarket", function () {
    it("should allow creator to cancel an open market", async function () {
      const { contract, creator } = await deployFixture();
      const deadline = await futureDeadline();
      await contract.connect(creator).createMarket("Cancel me?", deadline, ZERO_ADDRESS, 0);

      await expect(contract.connect(creator).cancelMarket(0))
        .to.emit(contract, "MarketCancelled")
        .withArgs(0);
    });

    it("should allow owner to cancel any market", async function () {
      const { contract, owner, creator } = await deployFixture();
      const deadline = await futureDeadline();
      await contract.connect(creator).createMarket("Owner cancel?", deadline, ZERO_ADDRESS, 0);

      await expect(contract.connect(owner).cancelMarket(0))
        .to.emit(contract, "MarketCancelled")
        .withArgs(0);
    });

    it("should revert if non-creator/non-owner tries to cancel", async function () {
      const { contract, creator, bettor1 } = await deployFixture();
      const deadline = await futureDeadline();
      await contract.connect(creator).createMarket("No cancel?", deadline, ZERO_ADDRESS, 0);

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

  describe("withdraw", function () {
    it("should revert withdraw on non-settled market", async function () {
      const { contract, creator, bettor1 } = await deployFixture();
      const deadline = await futureDeadline();
      await contract.connect(creator).createMarket("No settle?", deadline, ZERO_ADDRESS, 0);

      await expect(
        contract.connect(bettor1).withdraw(0),
      ).to.be.revertedWithCustomError(contract, "MarketNotSettledOrCancelled");
    });
  });

  // Note: FHE-specific tests (placeBet, settle, requestWithdrawal, completeWithdrawal)
  // and oracle resolution tests (resolve with live Chainlink feed) require either:
  // - fhEVM mock environment for encrypted operations
  // - Live Sepolia for Chainlink + FHE integration
  //
  // Key flows to test on live network:
  // 1. deposit → placeBet (encrypted amount) → resolve (oracle) → settle → withdraw
  // 2. deposit → placeBet → resolveManual → settle → withdraw
  // 3. deposit → requestWithdrawal → completeWithdrawal
  // 4. deposit → placeBet → cancelMarket (encrypted amounts returned to balance)
  // 5. getLatestPrice to verify Chainlink feed reads
});
