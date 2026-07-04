// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint8, externalEuint8} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ShieldOdds — Confidential Prediction Market (FHE-native)
/// @notice A prediction market where bet directions are encrypted using FHEVM.
///         Only the direction (YES/NO) is encrypted; bet amounts are public (ETH value).
/// @dev Built on Zama's fhevm-hardhat-template. Uses euint8 for encrypted bet sides
///      and KMS public decryption for settlement.
contract ShieldOdds is ZamaEthereumConfig {

    // ───────────────────────── Types ─────────────────────────

    enum MarketStatus {
        Open,       // accepting bets
        Resolved,   // outcome set by creator, awaiting settlement
        Settled,    // bets decrypted + payouts computed
        Cancelled   // refund scenario (no bets on winning side)
    }

    struct Market {
        string question;
        address creator;
        uint256 deadline;
        MarketStatus status;
        uint8 outcome;              // 0 = NO, 1 = YES (set after resolution)
        uint256 totalPool;          // sum of all bet amounts (ETH)
        uint256 totalWinningPool;   // sum of winning-side bet amounts (set during settle)
        uint256 betCount;
    }

    struct Bet {
        address bettor;
        uint256 amount;             // public (msg.value)
        euint8 encryptedSide;       // encrypted: 0 = NO, 1 = YES
        uint8 revealedSide;         // set during settlement
        bool settled;
        bool claimed;
    }

    // ───────────────────────── State ─────────────────────────

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(uint256 => Bet)) internal _bets;
    mapping(uint256 => mapping(address => uint256[])) internal _userBetIds;
    mapping(uint256 => mapping(address => uint256)) public payouts;

    uint256 public constant MIN_BET = 0.001 ether;
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%
    address public owner;
    uint256 public accumulatedFees;

    // ───────────────────────── Events ────────────────────────

    event MarketCreated(uint256 indexed marketId, string question, uint256 deadline, address creator);
    event BetPlaced(uint256 indexed marketId, uint256 indexed betId, address indexed bettor, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint8 outcome);
    event MarketSettled(uint256 indexed marketId, uint256 winningPool, uint256 losingPool);
    event MarketCancelled(uint256 indexed marketId);
    event BetRevealed(uint256 indexed marketId, uint256 indexed betId, uint8 side);
    event Withdrawal(uint256 indexed marketId, address indexed user, uint256 amount);
    event FeeWithdrawal(address indexed to, uint256 amount);

    // ───────────────────────── Errors ────────────────────────

    error NotOwner();
    error DeadlineMustBeInFuture();
    error MarketNotOpen();
    error BettingClosed();
    error BetTooSmall();
    error OnlyCreator();
    error DeadlineNotReached();
    error InvalidOutcome();
    error MarketNotResolved();
    error HandleCountMismatch();
    error HandleMismatch(uint256 betIndex);
    error NothingToWithdraw();
    error TransferFailed();
    error MarketNotSettledOrCancelled();
    error BetNotSettled();
    error SingleBetOnly();

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
    //                    CORE FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Create a new prediction market.
    /// @param question The question being predicted (e.g., "Will ETH hit $10k by Dec 2025?")
    /// @param deadline Unix timestamp after which betting closes
    /// @return marketId The ID of the newly created market
    function createMarket(
        string calldata question,
        uint256 deadline
    ) external returns (uint256 marketId) {
        if (deadline <= block.timestamp) revert DeadlineMustBeInFuture();

        marketId = marketCount++;
        Market storage m = markets[marketId];
        m.question = question;
        m.creator = msg.sender;
        m.deadline = deadline;
        m.status = MarketStatus.Open;

        emit MarketCreated(marketId, question, deadline, msg.sender);
    }

    /// @notice Place a bet on a market with an encrypted side.
    /// @dev Only the bet DIRECTION is encrypted (euint8: 0=NO, 1=YES).
    ///      The bet amount is public (msg.value in ETH).
    /// @param marketId The market to bet on
    /// @param encryptedSide The encrypted bet direction (euint8)
    /// @param inputProof Proof for the encrypted input
    function placeBet(
        uint256 marketId,
        externalEuint8 encryptedSide,
        bytes calldata inputProof
    ) external payable {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Open) revert MarketNotOpen();
        if (block.timestamp >= m.deadline) revert BettingClosed();
        if (msg.value < MIN_BET) revert BetTooSmall();

        // Verify and convert the encrypted input
        euint8 side = FHE.fromExternal(encryptedSide, inputProof);
        FHE.allowThis(side);

        uint256 betId = m.betCount++;
        Bet storage b = _bets[marketId][betId];
        b.bettor = msg.sender;
        b.amount = msg.value;
        b.encryptedSide = side;

        m.totalPool += msg.value;
        _userBetIds[marketId][msg.sender].push(betId);

        emit BetPlaced(marketId, betId, msg.sender, msg.value);
    }

    /// @notice Resolve a market by setting the outcome. Only callable by the market creator after deadline.
    /// @param marketId The market to resolve
    /// @param outcome The outcome: 0 = NO, 1 = YES
    function resolve(uint256 marketId, uint8 outcome) external {
        Market storage m = markets[marketId];
        if (msg.sender != m.creator) revert OnlyCreator();
        if (m.status != MarketStatus.Open) revert MarketNotOpen();
        if (block.timestamp < m.deadline) revert DeadlineNotReached();
        if (outcome > 1) revert InvalidOutcome();

        m.outcome = outcome;
        m.status = MarketStatus.Resolved;

        emit MarketResolved(marketId, outcome);
    }

    /// @notice Settle a market by providing KMS-decrypted bet sides with proof.
    /// @dev Anyone can call this after the market is resolved. The function:
    ///      1. Verifies the KMS decryption proof against stored encrypted handles
    ///      2. Categorizes each bet as winning or losing
    ///      3. Computes pro-rata payouts for winners
    ///      4. If no one bet on the winning side, cancels and refunds all bettors
    /// @param marketId The resolved market to settle
    /// @param abiEncodedCleartexts ABI-encoded decrypted bet sides from KMS
    /// @param decryptionProof KMS decryption proof (signatures + metadata)
    function settle(
        uint256 marketId,
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Resolved) revert MarketNotResolved();

        uint256 betCount = m.betCount;

        // Build handles list from stored encrypted bets
        bytes32[] memory handlesList = new bytes32[](betCount);
        for (uint256 i = 0; i < betCount; i++) {
            handlesList[i] = euint8.unwrap(_bets[marketId][i].encryptedSide);
        }

        // Verify KMS decryption proof — reverts if invalid
        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // Parse decrypted sides from ABI-encoded cleartexts
        // Each euint8 decrypts to a uint8, ABI-encoded as 32 bytes each
        uint8[] memory sides = _decodeSides(abiEncodedCleartexts, betCount);

        // Categorize bets and compute pools
        uint256 winningPool;
        uint256 losingPool;

        for (uint256 i = 0; i < betCount; i++) {
            Bet storage b = _bets[marketId][i];
            b.revealedSide = sides[i];
            b.settled = true;

            if (sides[i] == m.outcome) {
                winningPool += b.amount;
            } else {
                losingPool += b.amount;
            }

            emit BetRevealed(marketId, i, sides[i]);
        }

        m.totalWinningPool = winningPool;

        // ── Refund path: no one bet on the winning side ──
        if (winningPool == 0) {
            m.status = MarketStatus.Cancelled;
            for (uint256 i = 0; i < betCount; i++) {
                Bet storage b = _bets[marketId][i];
                payouts[marketId][b.bettor] += b.amount;
            }
            emit MarketCancelled(marketId);
            return;
        }

        // ── Normal path: compute pro-rata payouts ──
        uint256 protocolFee = (m.totalPool * PROTOCOL_FEE_BPS) / 10000;
        uint256 distributablePool = m.totalPool - protocolFee;

        for (uint256 i = 0; i < betCount; i++) {
            Bet storage b = _bets[marketId][i];
            if (b.revealedSide == m.outcome) {
                // Pro-rata: (betAmount / winningPool) * distributablePool
                payouts[marketId][b.bettor] += (b.amount * distributablePool) / winningPool;
            }
        }

        accumulatedFees += protocolFee;
        m.status = MarketStatus.Settled;

        emit MarketSettled(marketId, winningPool, losingPool);
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

        emit Withdrawal(marketId, msg.sender, payout);
    }

    /// @notice Verify that a specific bet was correctly decrypted during settlement.
    /// @dev FHE audit function — allows anyone to independently verify a bet reveal
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
        if (handlesList[0] != euint8.unwrap(b.encryptedSide)) revert HandleMismatch(betId);

        // Verify using the view variant (no event emission)
        valid = FHE.isPublicDecryptionResultValid(
            handlesList,
            abiEncodedCleartexts,
            decryptionProof
        );

        if (valid) {
            // Check the decrypted value matches what was recorded
            uint8 decryptedSide = abi.decode(abiEncodedCleartexts, (uint8));
            valid = (decryptedSide == b.revealedSide);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                    ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Cancel a market before deadline (creator or owner only). Refunds all bettors.
    /// @param marketId The market to cancel
    function cancelMarket(uint256 marketId) external {
        Market storage m = markets[marketId];
        if (msg.sender != m.creator && msg.sender != owner) revert OnlyCreator();
        if (m.status != MarketStatus.Open) revert MarketNotOpen();

        m.status = MarketStatus.Cancelled;

        // Refund all bettors
        for (uint256 i = 0; i < m.betCount; i++) {
            Bet storage b = _bets[marketId][i];
            payouts[marketId][b.bettor] += b.amount;
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
            uint256 totalPool,
            uint256 totalWinningPool,
            uint256 betCount
        )
    {
        Market storage m = markets[marketId];
        return (
            m.question,
            m.creator,
            m.deadline,
            m.status,
            m.outcome,
            m.totalPool,
            m.totalWinningPool,
            m.betCount
        );
    }

    /// @notice Get a specific bet's details (excluding encrypted handle for gas).
    function getBet(uint256 marketId, uint256 betId)
        external
        view
        returns (
            address bettor,
            uint256 amount,
            uint8 revealedSide,
            bool settled,
            bool claimed
        )
    {
        Bet storage b = _bets[marketId][betId];
        return (b.bettor, b.amount, b.revealedSide, b.settled, b.claimed);
    }

    /// @notice Get the encrypted handle (bytes32) for a bet — needed for decryption requests.
    function getBetHandle(uint256 marketId, uint256 betId) external view returns (bytes32) {
        return euint8.unwrap(_bets[marketId][betId].encryptedSide);
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
            handles[i] = euint8.unwrap(_bets[marketId][i].encryptedSide);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                    INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Decode ABI-encoded cleartexts into uint8 array.
    ///      The KMS encodes each euint8 cleartext as a 32-byte ABI word.
    function _decodeSides(
        bytes calldata abiEncodedCleartexts,
        uint256 count
    ) internal pure returns (uint8[] memory sides) {
        require(abiEncodedCleartexts.length >= count * 32, "Cleartexts too short");
        sides = new uint8[](count);
        for (uint256 i = 0; i < count; i++) {
            // Each value is in the last byte of its 32-byte ABI word
            sides[i] = uint8(uint256(bytes32(abiEncodedCleartexts[i * 32 : (i + 1) * 32])));
        }
    }

    /// @dev Fallback to receive ETH (for edge cases).
    receive() external payable {}
}
