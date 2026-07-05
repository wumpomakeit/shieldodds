// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title Chainlink AggregatorV3Interface (minimal)
/// @dev Only the functions we need — no npm dependency required.
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

/// @title FHESafeMath — Safe arithmetic for encrypted values
/// @notice Adapted from OpenZeppelin Confidential Contracts (v0.5.0)
/// @dev Handles uninitialized euint64 (bytes32(0) ≡ 0) gracefully.
library FHESafeMath {
    /// @dev Try to increase `oldValue` by `delta`. Returns (true, oldValue+delta) on success,
    ///      or (false, oldValue) on overflow.
    function tryIncrease(euint64 oldValue, euint64 delta) internal returns (ebool success, euint64 updated) {
        if (!FHE.isInitialized(oldValue)) {
            return (FHE.asEbool(true), delta);
        }
        euint64 newValue = FHE.add(oldValue, delta);
        success = FHE.ge(newValue, oldValue);
        updated = FHE.select(success, newValue, oldValue);
    }

    /// @dev Try to decrease `oldValue` by `delta`. Returns (true, oldValue-delta) on success,
    ///      or (false, oldValue) on underflow.
    function tryDecrease(euint64 oldValue, euint64 delta) internal returns (ebool success, euint64 updated) {
        if (!FHE.isInitialized(oldValue)) {
            if (!FHE.isInitialized(delta)) {
                return (FHE.asEbool(true), oldValue);
            }
            return (FHE.eq(delta, FHE.asEuint64(0)), FHE.asEuint64(0));
        }
        success = FHE.ge(oldValue, delta);
        updated = FHE.select(success, FHE.sub(oldValue, delta), oldValue);
    }
}

/// @title ShieldOdds — Confidential Prediction Market (FHE-native, Chainlink Oracle)
/// @notice A prediction market where bet AMOUNTS are encrypted using FHEVM.
///         Bet directions (YES/NO) are public; bet sizes are hidden on-chain via FHE
///         to prevent whale tracking and size-based front-running.
///         Markets can be resolved automatically via Chainlink price feeds
///         or manually by the creator.
/// @dev Built on Zama's fhevm-hardhat-template.
///      - Users deposit ETH → encrypted internal balance (euint64)
///      - Bets deduct from encrypted balance; direction is public, amount is encrypted
///      - Oracle markets: resolve() reads Chainlink price feed → auto-determines outcome
///      - Manual markets: resolveManual() lets creator set outcome
///      - Settlement decrypts amounts via KMS for pro-rata payout calculation
///      - Unused balance can be withdrawn via async two-step pattern (KMS verification)
contract ShieldOdds is ZamaEthereumConfig {
    using FHESafeMath for euint64;

    // ───────────────────────── Types ─────────────────────────

    enum MarketStatus {
        Open,       // accepting bets
        Resolved,   // outcome set, awaiting settlement
        Settled,    // bets decrypted + payouts computed
        Cancelled   // refund scenario
    }

    struct Market {
        string question;
        address creator;
        uint256 deadline;
        MarketStatus status;
        uint8 outcome;              // 0 = NO, 1 = YES (set after resolution)
        uint256 betCount;           // public counter (bet amounts hidden)
        // ── Chainlink Oracle fields ──
        address priceFeed;          // Chainlink aggregator (address(0) = manual market)
        int256 targetPrice;         // target price in feed's decimals (e.g. 8 for USD feeds)
        int256 resolvedPrice;       // actual price at resolution (0 for manual markets)
    }

    struct Bet {
        address bettor;
        uint8 side;                 // PUBLIC: 0 = NO, 1 = YES
        euint64 encryptedAmount;    // ENCRYPTED bet size
        uint256 revealedAmount;     // set during settlement (plaintext)
        bool settled;
    }

    struct WithdrawalRequest {
        address user;
        uint256 amount;             // plaintext requested amount
        bytes32 successHandle;      // handle of the ebool success flag
        bool completed;
        bool cancelled;
    }

    // ───────────────────────── State ─────────────────────────

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(uint256 => Bet)) internal _bets;
    mapping(uint256 => mapping(address => uint256[])) internal _userBetIds;
    mapping(uint256 => mapping(address => uint256)) public payouts;

    /// @notice Encrypted internal balances — deposit ETH to fund, deducted by bets
    mapping(address => euint64) private _balances;

    /// @notice Async withdrawal requests (balance → ETH)
    uint256 public withdrawalCount;
    mapping(uint256 => WithdrawalRequest) public withdrawals;

    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%
    address public owner;
    uint256 public accumulatedFees;

    /// @notice Maximum staleness for Chainlink price feed data (24h for testnet)
    uint256 public constant MAX_PRICE_STALENESS = 24 hours;

    // ───────────────────────── Events ────────────────────────

    event Deposited(address indexed user, uint256 amount);
    event MarketCreated(
        uint256 indexed marketId,
        string question,
        uint256 deadline,
        address creator,
        address priceFeed,
        int256 targetPrice
    );
    event BetPlaced(uint256 indexed marketId, uint256 indexed betId, address indexed bettor, uint8 side);
    event MarketResolved(uint256 indexed marketId, uint8 outcome, int256 resolvedPrice);
    event MarketSettled(uint256 indexed marketId, uint256 totalPool, uint256 winningPool);
    event MarketCancelled(uint256 indexed marketId);
    event BetRevealed(uint256 indexed marketId, uint256 indexed betId, uint256 amount);
    event PayoutWithdrawal(uint256 indexed marketId, address indexed user, uint256 amount);
    event WithdrawalRequested(uint256 indexed requestId, address indexed user, uint256 amount);
    event WithdrawalCompleted(uint256 indexed requestId, address indexed user, uint256 amount);
    event WithdrawalCancelled(uint256 indexed requestId);
    event FeeWithdrawal(address indexed to, uint256 amount);

    // ───────────────────────── Errors ────────────────────────

    error NotOwner();
    error DeadlineMustBeInFuture();
    error MarketNotOpen();
    error BettingClosed();
    error OnlyCreator();
    error DeadlineNotReached();
    error InvalidOutcome();
    error InvalidSide();
    error MarketNotResolved();
    error NothingToWithdraw();
    error TransferFailed();
    error MarketNotSettledOrCancelled();
    error ZeroDeposit();
    error DepositTooLarge();
    error ZeroAmount();
    error AmountTooLarge();
    error RequestAlreadyProcessed();
    error HandleCountMismatch();
    error HandleMismatch(uint256 index);
    error BetNotSettled();
    error SingleBetOnly();
    error NotOracleMarket();
    error IsOracleMarket();
    error StalePriceFeed();
    error InvalidPriceFeed();

    // ───────────────────────── Modifiers ─────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ───────────────────────── Constructor ───────────────────

    constructor() {
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════
    //                    DEPOSIT / WITHDRAW BALANCE
    // ═══════════════════════════════════════════════════════════

    /// @notice Deposit ETH into encrypted internal balance.
    /// @dev The deposit amount is public (ETH transfer visible on-chain).
    ///      The resulting balance is encrypted — observers cannot track how
    ///      much of the balance is allocated to specific bets.
    function deposit() external payable {
        if (msg.value == 0) revert ZeroDeposit();
        if (msg.value > type(uint64).max) revert DepositTooLarge();

        euint64 amount = FHE.asEuint64(uint64(msg.value));
        euint64 currentBalance = _balances[msg.sender];

        euint64 newBalance;
        if (!FHE.isInitialized(currentBalance)) {
            newBalance = amount;
        } else {
            newBalance = FHE.add(currentBalance, amount);
        }

        _balances[msg.sender] = newBalance;
        FHE.allowThis(newBalance);
        FHE.allow(newBalance, msg.sender);

        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Request withdrawal of unused balance back to ETH.
    /// @dev Two-step async pattern:
    ///      1. This function deducts from encrypted balance and marks a success flag for KMS decryption
    ///      2. After KMS decrypts, call completeWithdrawal() with the proof
    ///      If the balance was insufficient, tryDecrease leaves it unchanged and success = false.
    /// @param amount The plaintext amount to withdraw (in wei)
    /// @return requestId The withdrawal request ID
    function requestWithdrawal(uint256 amount) external returns (uint256 requestId) {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint64).max) revert AmountTooLarge();

        euint64 encAmount = FHE.asEuint64(uint64(amount));
        (ebool success, euint64 newBalance) = _balances[msg.sender].tryDecrease(encAmount);

        // Update balance (unchanged if insufficient, reduced if sufficient)
        _balances[msg.sender] = newBalance;
        FHE.allowThis(newBalance);
        FHE.allow(newBalance, msg.sender);

        // Mark success flag for public decryption by KMS
        FHE.makePubliclyDecryptable(success);

        requestId = withdrawalCount++;
        withdrawals[requestId] = WithdrawalRequest({
            user: msg.sender,
            amount: amount,
            successHandle: ebool.unwrap(success),
            completed: false,
            cancelled: false
        });

        emit WithdrawalRequested(requestId, msg.sender, amount);
    }

    /// @notice Complete a pending withdrawal after KMS has decrypted the success flag.
    /// @dev Anyone can call this with a valid KMS proof. If success was true, ETH is sent.
    ///      If success was false (insufficient balance at request time), the request is cancelled.
    /// @param requestId The withdrawal request ID
    /// @param abiEncodedCleartext ABI-encoded decrypted success flag from KMS
    /// @param decryptionProof KMS decryption proof
    function completeWithdrawal(
        uint256 requestId,
        bytes calldata abiEncodedCleartext,
        bytes calldata decryptionProof
    ) external {
        WithdrawalRequest storage req = withdrawals[requestId];
        if (req.completed || req.cancelled) revert RequestAlreadyProcessed();

        // Verify KMS decryption proof
        bytes32[] memory handles = new bytes32[](1);
        handles[0] = req.successHandle;
        FHE.checkSignatures(handles, abiEncodedCleartext, decryptionProof);

        // Parse the decrypted ebool (ABI-encoded as 32-byte word, last byte is 0 or 1)
        bool success = uint256(bytes32(abiEncodedCleartext[0:32])) != 0;

        if (success) {
            req.completed = true;
            (bool sent, ) = req.user.call{value: req.amount}("");
            if (!sent) revert TransferFailed();
            emit WithdrawalCompleted(requestId, req.user, req.amount);
        } else {
            // Balance was insufficient — tryDecrease left it unchanged
            req.cancelled = true;
            emit WithdrawalCancelled(requestId);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                    CORE MARKET FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Create a new prediction market.
    /// @param question The question being predicted (e.g. "Will BTC reach $100k before July 31?")
    /// @param deadline Unix timestamp after which betting closes and resolution can occur
    /// @param priceFeed Chainlink aggregator address for oracle resolution (address(0) for manual)
    /// @param targetPrice Target price in the feed's native decimals (e.g. 100000e8 for $100k USD).
    ///        Ignored if priceFeed is address(0).
    /// @return marketId The ID of the newly created market
    function createMarket(
        string calldata question,
        uint256 deadline,
        address priceFeed,
        int256 targetPrice
    ) external returns (uint256 marketId) {
        if (deadline <= block.timestamp) revert DeadlineMustBeInFuture();

        // Validate the Chainlink feed if provided
        if (priceFeed != address(0)) {
            // Quick sanity check: try to read decimals (reverts if not a valid feed)
            try AggregatorV3Interface(priceFeed).decimals() returns (uint8) {
                // valid
            } catch {
                revert InvalidPriceFeed();
            }
        }

        marketId = marketCount++;
        Market storage m = markets[marketId];
        m.question = question;
        m.creator = msg.sender;
        m.deadline = deadline;
        m.status = MarketStatus.Open;
        m.priceFeed = priceFeed;
        m.targetPrice = targetPrice;

        emit MarketCreated(marketId, question, deadline, msg.sender, priceFeed, targetPrice);
    }

    /// @notice Place a bet on a market with a public side and encrypted amount.
    /// @dev The bet DIRECTION is public (YES/NO). The bet AMOUNT is encrypted (euint64),
    ///      drawn from the user's internal encrypted balance.
    ///      If the balance is insufficient, the effective bet amount is silently zero'd
    ///      (balance unchanged, bet records a zero amount). Frontend should validate balance.
    /// @param marketId The market to bet on
    /// @param side The bet direction: 0 = NO, 1 = YES (public)
    /// @param encryptedAmount The encrypted bet amount (euint64)
    /// @param inputProof Proof for the encrypted input
    function placeBet(
        uint256 marketId,
        uint8 side,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Open) revert MarketNotOpen();
        if (block.timestamp >= m.deadline) revert BettingClosed();
        if (side > 1) revert InvalidSide();

        // Verify and convert the encrypted input
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        FHE.allowThis(amount);

        // Deduct from encrypted balance
        (ebool success, euint64 newBalance) = _balances[msg.sender].tryDecrease(amount);

        // If insufficient balance, effective bet = 0; otherwise effective bet = amount
        euint64 effectiveAmount = FHE.select(success, amount, FHE.asEuint64(0));
        FHE.allowThis(effectiveAmount);

        // Update balance
        _balances[msg.sender] = newBalance;
        FHE.allowThis(newBalance);
        FHE.allow(newBalance, msg.sender);

        // Store the bet
        uint256 betId = m.betCount++;
        Bet storage b = _bets[marketId][betId];
        b.bettor = msg.sender;
        b.side = side;
        b.encryptedAmount = effectiveAmount;

        _userBetIds[marketId][msg.sender].push(betId);

        emit BetPlaced(marketId, betId, msg.sender, side);
    }

    /// @notice Resolve an oracle market using Chainlink price feed data.
    /// @dev Permissionless — anyone can call after the deadline passes.
    ///      Reads the latest price from the market's Chainlink feed and compares to targetPrice.
    ///      YES (outcome=1) if price >= targetPrice, NO (outcome=0) if price < targetPrice.
    ///      Also marks all bet amounts for KMS decryption so settle() can proceed.
    /// @param marketId The oracle market to resolve
    function resolve(uint256 marketId) external {
        Market storage m = markets[marketId];
        if (m.priceFeed == address(0)) revert NotOracleMarket();
        if (m.status != MarketStatus.Open) revert MarketNotOpen();
        if (block.timestamp < m.deadline) revert DeadlineNotReached();

        // Read latest price from Chainlink
        AggregatorV3Interface feed = AggregatorV3Interface(m.priceFeed);
        (
            ,
            int256 price,
            ,
            uint256 updatedAt,

        ) = feed.latestRoundData();

        // Staleness check
        if (block.timestamp - updatedAt > MAX_PRICE_STALENESS) revert StalePriceFeed();

        // Determine outcome: YES if price >= target, NO otherwise
        uint8 outcome = price >= m.targetPrice ? 1 : 0;

        m.outcome = outcome;
        m.resolvedPrice = price;
        m.status = MarketStatus.Resolved;

        // Mark all encrypted bet amounts for public decryption
        uint256 betCount = m.betCount;
        for (uint256 i = 0; i < betCount; i++) {
            FHE.makePubliclyDecryptable(_bets[marketId][i].encryptedAmount);
        }

        emit MarketResolved(marketId, outcome, price);
    }

    /// @notice Resolve a manual (non-oracle) market by setting the outcome.
    /// @dev Only callable by the market creator after the deadline.
    ///      For oracle markets, use resolve() instead.
    /// @param marketId The manual market to resolve
    /// @param outcome The outcome: 0 = NO, 1 = YES
    function resolveManual(uint256 marketId, uint8 outcome) external {
        Market storage m = markets[marketId];
        if (m.priceFeed != address(0)) revert IsOracleMarket();
        if (msg.sender != m.creator) revert OnlyCreator();
        if (m.status != MarketStatus.Open) revert MarketNotOpen();
        if (block.timestamp < m.deadline) revert DeadlineNotReached();
        if (outcome > 1) revert InvalidOutcome();

        m.outcome = outcome;
        m.status = MarketStatus.Resolved;

        // Mark all encrypted bet amounts for public decryption
        uint256 betCount = m.betCount;
        for (uint256 i = 0; i < betCount; i++) {
            FHE.makePubliclyDecryptable(_bets[marketId][i].encryptedAmount);
        }

        emit MarketResolved(marketId, outcome, int256(0));
    }

    /// @notice Settle a market by providing KMS-decrypted bet amounts with proof.
    /// @dev Anyone can call this after the market is resolved. The function:
    ///      1. Verifies KMS decryption proofs against stored encrypted handles
    ///      2. Computes total pool and winning pool from revealed plaintext amounts
    ///      3. Computes pro-rata payouts for winners
    ///      4. If no one bet on the winning side, cancels and credits refunds
    /// @param marketId The resolved market to settle
    /// @param abiEncodedCleartexts ABI-encoded decrypted bet amounts from KMS
    /// @param decryptionProof KMS decryption proof
    function settle(
        uint256 marketId,
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Resolved) revert MarketNotResolved();

        uint256 betCount = m.betCount;

        // Build handles list from stored encrypted bet amounts
        bytes32[] memory handlesList = new bytes32[](betCount);
        for (uint256 i = 0; i < betCount; i++) {
            handlesList[i] = euint64.unwrap(_bets[marketId][i].encryptedAmount);
        }

        // Verify KMS decryption proof — reverts if invalid
        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // Parse decrypted amounts from ABI-encoded cleartexts
        // Each euint64 decrypts to a uint64, ABI-encoded as 32 bytes each
        uint64[] memory amounts = _decodeAmounts(abiEncodedCleartexts, betCount);

        // Compute pools using revealed plaintext values
        uint256 totalPool;
        uint256 winningPool;

        for (uint256 i = 0; i < betCount; i++) {
            Bet storage b = _bets[marketId][i];
            uint256 amount = uint256(amounts[i]);
            b.revealedAmount = amount;
            b.settled = true;
            totalPool += amount;

            if (b.side == m.outcome) {
                winningPool += amount;
            }

            emit BetRevealed(marketId, i, amount);
        }

        // ── Refund path: no one bet on the winning side ──
        if (winningPool == 0) {
            m.status = MarketStatus.Cancelled;
            for (uint256 i = 0; i < betCount; i++) {
                Bet storage b = _bets[marketId][i];
                payouts[marketId][b.bettor] += b.revealedAmount;
            }
            emit MarketCancelled(marketId);
            return;
        }

        // ── Normal path: compute pro-rata payouts ──
        uint256 protocolFee = (totalPool * PROTOCOL_FEE_BPS) / 10000;
        uint256 distributablePool = totalPool - protocolFee;

        for (uint256 i = 0; i < betCount; i++) {
            Bet storage b = _bets[marketId][i];
            if (b.side == m.outcome) {
                payouts[marketId][b.bettor] += (b.revealedAmount * distributablePool) / winningPool;
            }
        }

        accumulatedFees += protocolFee;
        m.status = MarketStatus.Settled;

        emit MarketSettled(marketId, totalPool, winningPool);
    }

    /// @notice Withdraw winnings (or refund) from a settled/cancelled market.
    /// @param marketId The market to withdraw from
    function withdraw(uint256 marketId) external {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Settled && m.status != MarketStatus.Cancelled) {
            revert MarketNotSettledOrCancelled();
        }

        uint256 payout = payouts[marketId][msg.sender];
        if (payout == 0) revert NothingToWithdraw();

        payouts[marketId][msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: payout}("");
        if (!sent) revert TransferFailed();

        emit PayoutWithdrawal(marketId, msg.sender, payout);
    }

    /// @notice Verify that a specific bet amount was correctly decrypted during settlement.
    /// @dev FHE audit function — allows anyone to independently verify a bet's revealed amount
    ///      by providing a fresh KMS decryption proof for a single bet.
    /// @param marketId The market the bet belongs to
    /// @param betId The bet to verify
    /// @param handlesList Single-element array with the bet's encrypted handle
    /// @param abiEncodedCleartexts ABI-encoded decrypted value
    /// @param decryptionProof KMS proof for this specific bet
    /// @return valid True if the decrypted value matches what was recorded during settlement
    function verifyReveal(
        uint256 marketId,
        uint256 betId,
        bytes32[] calldata handlesList,
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external view returns (bool valid) {
        Bet storage b = _bets[marketId][betId];
        if (!b.settled) revert BetNotSettled();
        if (handlesList.length != 1) revert SingleBetOnly();
        if (handlesList[0] != euint64.unwrap(b.encryptedAmount)) revert HandleMismatch(betId);

        valid = FHE.isPublicDecryptionResultValid(
            handlesList,
            abiEncodedCleartexts,
            decryptionProof
        );

        if (valid) {
            uint64 decryptedAmount = uint64(uint256(bytes32(abiEncodedCleartexts[0:32])));
            valid = (uint256(decryptedAmount) == b.revealedAmount);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Cancel a market before settlement. Returns encrypted bet amounts to user balances.
    /// @dev No KMS decryption needed — encrypted amounts are added back directly.
    ///      Users can then use their restored balance for new bets or withdraw via requestWithdrawal().
    /// @param marketId The market to cancel
    function cancelMarket(uint256 marketId) external {
        Market storage m = markets[marketId];
        if (msg.sender != m.creator && msg.sender != owner) revert OnlyCreator();
        if (m.status != MarketStatus.Open) revert MarketNotOpen();

        m.status = MarketStatus.Cancelled;

        // Return encrypted bet amounts to user balances (no decryption needed)
        for (uint256 i = 0; i < m.betCount; i++) {
            Bet storage b = _bets[marketId][i];
            euint64 currentBalance = _balances[b.bettor];

            euint64 newBalance;
            if (!FHE.isInitialized(currentBalance)) {
                newBalance = b.encryptedAmount;
            } else {
                newBalance = FHE.add(currentBalance, b.encryptedAmount);
            }

            _balances[b.bettor] = newBalance;
            FHE.allowThis(newBalance);
            FHE.allow(newBalance, b.bettor);
        }

        emit MarketCancelled(marketId);
    }

    /// @notice Withdraw accumulated protocol fees (owner only).
    function withdrawFees() external onlyOwner {
        uint256 fees = accumulatedFees;
        if (fees == 0) revert NothingToWithdraw();

        accumulatedFees = 0;

        (bool sent, ) = owner.call{value: fees}("");
        if (!sent) revert TransferFailed();

        emit FeeWithdrawal(owner, fees);
    }

    /// @notice Transfer contract ownership.
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    // ═══════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Get full market details.
    function getMarket(uint256 marketId)
        external
        view
        returns (
            string memory question,
            address creator,
            uint256 deadline,
            MarketStatus status,
            uint8 outcome,
            uint256 betCount,
            address priceFeed,
            int256 targetPrice,
            int256 resolvedPrice
        )
    {
        Market storage m = markets[marketId];
        return (
            m.question,
            m.creator,
            m.deadline,
            m.status,
            m.outcome,
            m.betCount,
            m.priceFeed,
            m.targetPrice,
            m.resolvedPrice
        );
    }

    /// @notice Get the latest price from a market's Chainlink feed.
    /// @dev Reverts if the market is not oracle-based.
    /// @param marketId The oracle market
    /// @return price The latest price from the feed
    /// @return feedDecimals The number of decimals the feed uses
    /// @return updatedAt When the feed was last updated
    function getLatestPrice(uint256 marketId)
        external
        view
        returns (int256 price, uint8 feedDecimals, uint256 updatedAt)
    {
        Market storage m = markets[marketId];
        if (m.priceFeed == address(0)) revert NotOracleMarket();

        AggregatorV3Interface feed = AggregatorV3Interface(m.priceFeed);
        (, price, , updatedAt, ) = feed.latestRoundData();
        feedDecimals = feed.decimals();
    }

    /// @notice Get a specific bet's public details.
    /// @dev revealedAmount is only set after settlement.
    function getBet(uint256 marketId, uint256 betId)
        external
        view
        returns (
            address bettor,
            uint8 side,
            uint256 revealedAmount,
            bool settled
        )
    {
        Bet storage b = _bets[marketId][betId];
        return (b.bettor, b.side, b.revealedAmount, b.settled);
    }

    /// @notice Get the encrypted handle (bytes32) for a bet amount — needed for decryption requests.
    function getBetHandle(uint256 marketId, uint256 betId) external view returns (bytes32) {
        return euint64.unwrap(_bets[marketId][betId].encryptedAmount);
    }

    /// @notice Get all bet IDs for a user in a market.
    function getUserBetIds(uint256 marketId, address user)
        external
        view
        returns (uint256[] memory)
    {
        return _userBetIds[marketId][user];
    }

    /// @notice Get all encrypted handles for a market — needed to request batch decryption.
    function getMarketHandles(uint256 marketId) external view returns (bytes32[] memory handles) {
        uint256 count = markets[marketId].betCount;
        handles = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            handles[i] = euint64.unwrap(_bets[marketId][i].encryptedAmount);
        }
    }

    /// @notice Get the encrypted balance handle for a user — needed for re-encryption (view own balance).
    /// @dev The user (or authorized parties) can use fhevmjs to re-encrypt this handle
    ///      and view their plaintext balance off-chain.
    function getBalanceHandle(address user) external view returns (bytes32) {
        return euint64.unwrap(_balances[user]);
    }

    /// @notice Get a withdrawal request's details.
    function getWithdrawalRequest(uint256 requestId)
        external
        view
        returns (
            address user,
            uint256 amount,
            bytes32 successHandle,
            bool completed,
            bool cancelled
        )
    {
        WithdrawalRequest storage req = withdrawals[requestId];
        return (req.user, req.amount, req.successHandle, req.completed, req.cancelled);
    }

    // ═══════════════════════════════════════════════════════════
    //                    INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Decode ABI-encoded cleartexts into uint64 array.
    ///      The KMS encodes each euint64 cleartext as a 32-byte ABI word.
    function _decodeAmounts(
        bytes calldata abiEncodedCleartexts,
        uint256 count
    ) internal pure returns (uint64[] memory amounts) {
        require(abiEncodedCleartexts.length >= count * 32, "Cleartexts too short");
        amounts = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            amounts[i] = uint64(uint256(bytes32(abiEncodedCleartexts[i * 32 : (i + 1) * 32])));
        }
    }

    /// @dev Fallback to receive ETH (for edge cases).
    receive() external payable {}
}
