# ShieldOdds — Agent Guide

ShieldOdds is an FHE-native confidential prediction market on Ethereum Sepolia.
It has two parts:

- **Smart contract** (`contracts/ShieldOdds.sol`) — a Hardhat + Zama FHEVM project.
  Standard commands live in `package.json` scripts and are documented in `README.md`
  (`npm run compile`, `npm test`, `npm run lint`, `npm run deploy:sepolia`, etc.).
- **Frontend** (`frontend/index.html`) — a single, static, dependency-free HTML page
  (inline CSS + JS, `ethers` and the Zama relayer SDK loaded from CDN / self-hosted
  bundles in `frontend/fhevm/`). There is no build step; `vercel.json` just serves the
  static files and exposes an `/api/rpc` proxy (`api/rpc.js`) on Vercel.

## Cursor Cloud specific instructions

- **Deployed contract:** the frontend talks to `CONTRACT_ADDRESS`
  `0x96BD5Fd9eD51b0c95C3B7a867DdB888f731Be5e2` on Sepolia (chainId `11155111`).
- **Running the frontend locally:** serve the `frontend/` directory statically, e.g.
  `python3 -m http.server 8000 --directory frontend`, then open
  `http://localhost:8000/index.html`. Do **not** open via `file://`. When served on
  `localhost`, the page detects `IS_LOCAL` and talks directly to the public Sepolia RPC
  (`https://ethereum-sepolia-rpc.publicnode.com`), so the `/api/rpc` Vercel proxy is
  **not** needed for local dev.
- **Wallet gating during testing:** most write flows (Create Market, Place Bet, etc.)
  require a connected browser wallet (MetaMask) on Sepolia, which the headless test
  browser does not have. To exercise UI/validation/data-conversion logic without a
  wallet, temporarily stub the module-scope `userAddress` and `contract` globals (they
  live in the classic `<script>` block) — add such stubs only for testing and never
  commit them.
- **Chainlink price feeds** used by the Create Market form are defined in the
  `CHAINLINK_FEEDS` object in `frontend/index.html`; the dropdown is generated from it,
  so add feeds by editing that object only.
- **Lint caveat (pre-existing on `main`):** `npm run lint` currently fails and is not a
  regression from frontend work. `lint:sol` reports one `code-complexity` error on
  `settle()`; `lint:ts` (eslint) lints the vendored minified bundles in
  `frontend/fhevm/*.min.js` (not ignored) producing thousands of errors; and
  `prettier:check` flags several existing files. HTML is not covered by any linter, so
  `frontend/index.html` edits are not lint-checked.
