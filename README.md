# 🛡️ ShieldOdds — Confidential Prediction Market

**FHE-native prediction market on Ethereum Sepolia** — bet directions are encrypted using Fully Homomorphic Encryption, keeping your position private until settlement.

## How It Works

| Step | Function | What Happens |
|------|----------|-------------|
| 1 | `createMarket()` | Creator sets a question and betting deadline |
| 2 | `placeBet()` | Users send ETH + encrypted side (YES/NO via FHE) |
| 3 | `resolve()` | Creator sets the outcome after deadline |
| 4 | `settle()` | KMS decrypts bet directions, pro-rata payouts computed |
| 5 | `withdraw()` | Winners claim their ETH |

> **Privacy model:** Only bet *direction* (YES/NO) is encrypted. Bet amounts are public (ETH value). This prevents front-running and manipulation of positions while keeping the economic activity transparent.

## Architecture

```
ShieldOdds.sol
├── createMarket()     — Create prediction market with question + deadline
├── placeBet()         — Encrypted bet direction (euint8) + public ETH deposit
├── resolve()          — Market creator sets outcome (YES=1, NO=0)
├── settle()           — KMS decryption proof → categorize winners → compute payouts
├── withdraw()         — Winners claim pro-rata ETH payout
├── verifyReveal()     — FHE audit: independently verify any bet's decryption
├── cancelMarket()     — Creator/owner can cancel → full refunds
└── View helpers       — getMarket, getBet, getMarketHandles, getUserBetIds
```

### Settlement Details

- **Winners** share the entire pool proportionally to their bet amounts
- **Protocol fee**: 1% deducted from total pool before distribution
- **Refund logic**: If no one bet on the winning side, all bettors get full refunds
- **Audit trail**: `verifyReveal()` allows anyone to re-verify any bet's decryption with a fresh KMS proof

## Tech Stack

- **Solidity 0.8.27** with Cancun EVM target
- **Zama FHEVM** (`@fhevm/solidity ^0.11.1`) for encrypted computation
- **Hardhat** with TypeScript, hardhat-deploy, typechain
- **KMS public decryption** via `FHE.checkSignatures()`

## Quick Start

```bash
# Install dependencies
npm install

# Compile contracts
npx hardhat compile

# Run tests (local mock chain)
npx hardhat test

# Deploy to Sepolia
npx hardhat vars set MNEMONIC "your twelve word mnemonic here"
npx hardhat deploy:sepolia
```

## Hardhat Tasks

```bash
# Create a market
npx hardhat shieldodds:createMarket \
  --question "Will ETH hit 10k by Dec 2025?" \
  --deadline 1735689600 \
  --network sepolia

# Query market details
npx hardhat shieldodds:getMarket --id 0 --network sepolia

# Resolve a market
npx hardhat shieldodds:resolve --id 0 --outcome 1 --network sepolia

# Get encrypted handles (for KMS decryption request)
npx hardhat shieldodds:getHandles --id 0 --network sepolia

# Contract info
npx hardhat shieldodds:info --network sepolia
```

## Network Configuration

| Network | Chain ID | RPC |
|---------|----------|-----|
| Sepolia | 11155111 | `https://ethereum-sepolia-rpc.publicnode.com` |
| Local (Hardhat) | 31337 | `http://localhost:8545` |

### Zama Coprocessor Addresses (Sepolia)

| Contract | Address |
|----------|---------|
| ACL | `0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D` |
| Coprocessor | `0x92C920834Ec8941d2C77D188936E1f7A6f49c127` |
| KMS Verifier | `0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A` |

## License

MIT
