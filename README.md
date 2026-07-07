# 🛡️ ShieldOdds — Confidential Prediction Market

[![Built with Zama fhEVM](https://img.shields.io/badge/Built%20with-Zama%20fhEVM-blue)](https://www.zama.ai/)
[![Deployed on Vercel](https://img.shields.io/badge/Deployed%20on-Vercel-black)](https://vercel.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)

> **Live Demo**: [shieldodds.fun](https://www.shieldodds.fun)  

**FHE-native prediction market with a clean, professional frontend.** Your bet amount stays encrypted using Fully Homomorphic Encryption — nobody sees how much you bet, not even the contract itself. Directions (YES/NO) remain public for transparency.

---

## How It Works

| Step | Function | What Happens |
|------|----------|-------------|
| 1 | `createMarket()` | Creator sets a question, Chainlink price feed, target price, and deadline |
| 2 | `placeBet()` | Users send encrypted bet amount (FHE) + public YES/NO direction |
| 3 | `resolve()` | Chainlink oracle auto-resolves when deadline passes |
| 4 | `settle()` | KMS decrypts all bet amounts simultaneously, pro-rata payouts computed |
| 5 | `withdraw()` | Winners claim their ETH share |

> **Privacy model:** Bet *amounts* are encrypted using FHE. Directions (YES/NO) are public. This prevents whale tracking and size-based front-running while keeping bet directions transparent. At settlement, KMS decrypts all amounts simultaneously for fair payout calculation.

---

## Features

### 🔐 FHE-Encrypted Bet Amounts
- Bet directions (YES/NO) are public on-chain
- Bet sizes are encrypted using Zama fhEVM
- No whale tracking, no size-based front-running
- KMS-verified decryption at settlement
- Anyone can independently verify decryption via `verifyReveal()`

### ⛓️ Chainlink Oracle Integration
- Automatic market resolution — no human intervention
- 7 live price feeds: BTC/USD, ETH/USD, LINK/USD, AAVE/USD, DAI/USD, USDC/USD, MATIC/USD
- Market resolves to YES if live price ≥ target price at deadline
- Fully transparent and verifiable on-chain

### 🎨 Clean, Professional UI
- Dark slate/blue accent design — fintech-grade
- No emoji clutter — focused on numbers and clarity
- Fully responsive (mobile + desktop)
- Live price display with target comparison
- Real-time market status and bet tracking

### 🧪 Testnet Live
- Deployed on Sepolia testnet
- Free test ETH from faucets
- No real funds at risk — perfect for testing and experimentation

---

## Architecture

```

ShieldOdds.sol
├── createMarket()     — Create prediction market with question + deadline
├── placeBet()         — Encrypted bet amount (euint64) + public YES/NO direction
├── resolve()          — Chainlink oracle auto-resolves when deadline passes
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

---

## Tech Stack

### Smart Contracts
- **Solidity 0.8.27** with Cancun EVM target
- **Zama FHEVM** (`@fhevm/solidity ^0.11.1`) for encrypted computation
- **Hardhat** with TypeScript, hardhat-deploy, typechain
- **KMS public decryption** via `FHE.checkSignatures()`

### Frontend
- **HTML/CSS/JavaScript** — no framework, lightweight
- **ethers.js** — blockchain interaction
- **fhevmjs** — FHE encryption client-side
- **Vercel** — hosting & auto-deploy from GitHub

### Oracles & Infrastructure
- **Chainlink Price Feeds** — 7 live feeds on Sepolia
- **Zama Coprocessor** — FHE computation on-chain
- **Sepolia Testnet** — Ethereum test network

---

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

---

Frontend (Live dApp)

The frontend is a single-page application built with vanilla HTML, CSS, and JavaScript, deployed on Vercel.

Live URLs

· Production (Custom Domain): shieldodds.fun
· Vercel Default: shieldodds.vercel.app

Frontend Features

· Wallet Connect — MetaMask, Rabby, or any Ethereum-compatible wallet
· Create Market Form — Chainlink oracle only (no manual resolution)
· Place Bet — FHE encryption client-side via fhevmjs
· Live Price Feeds — Real-time Chainlink data
· Claim Winnings — One-click withdrawal
· Responsive UI — Works on mobile and desktop

---

Hardhat Tasks

```bash
# Create a market
npx hardhat shieldodds:createMarket \
  --question "Will ETH hit 10k by Dec 2026?" \
  --deadline 1735689600 \
  --priceFeed 0x694AA1769357215DE4FAC081bf1f309aDC325306 \
  --targetPrice 100000000000 \
  --network sepolia

# Query market details
npx hardhat shieldodds:getMarket --id 0 --network sepolia

# Resolve a market
npx hardhat shieldodds:resolve --id 0 --network sepolia

# Get encrypted handles (for KMS decryption request)
npx hardhat shieldodds:getHandles --id 0 --network sepolia

# Contract info
npx hardhat shieldodds:info --network sepolia
```

---

Network Configuration

Network Chain ID RPC
Sepolia 11155111 https://ethereum-sepolia-rpc.publicnode.com
Local (Hardhat) 31337 http://localhost:8545

Zama Coprocessor Addresses (Sepolia)

Contract Address
ACL 0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D
Coprocessor 0x92C920834Ec8941d2C77D188936E1f7A6f49c127
KMS Verifier 0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A

Chainlink Price Feeds (Sepolia)

Feed Address Decimals
BTC/USD 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43 8
ETH/USD 0x694AA1769357215DE4FAC081bf1f309aDC325306 8
LINK/USD 0xc59E3633BAAC79493d908e63626716e204A45EdF 8
AAVE/USD 0x6Df09E975c830ECAE5bd4eD9d90f3A95a4f88012 8
DAI/USD 0x14866185B1962B63C3Ea9E71BcF85af7B950B5E6 8
USDC/USD 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E 8
MATIC/USD 0x7bAC85A8a13A4BcD8abb3eB7d6b9d095777A4C27 8

---

Contributing

Contributions are welcome! Here's how you can help:

1. Fork the repository
2. Create a feature branch (git checkout -b feature/amazing-feature)
3. Commit your changes (git commit -m 'Add some amazing feature')
4. Push to the branch (git push origin feature/amazing-feature)
5. Open a Pull Request

Development Guidelines

· Follow Solidity best practices
· Write tests for new features
· Update documentation accordingly

---

License

MIT License — feel free to use, modify, and distribute.

---

Acknowledgments

· Zama — FHEVM and fhevmjs
· Chainlink — Price feeds
· Vercel — Hosting
· Hardhat — Development framework
