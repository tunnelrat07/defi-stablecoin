# Decentralized Stablecoin (DSC) Engine

## Overview
This repository contains smart contracts for a decentralized stablecoin (DSC) system built on Ethereum. The DSC protocol allows users to deposit collateral (WETH, WBTC) and mint a stablecoin pegged to the USD. The system ensures over-collateralization, automatic liquidations, and price stability using Chainlink oracles.

### Features
- **Collateralized Stablecoin:** Users mint DSC by depositing over-collateralized assets.
- **Liquidation Mechanism:** Unhealthy positions can be liquidated to maintain solvency.
- **Chainlink Price Feeds:** Reliable asset pricing using Chainlink oracles.
- **ERC20 Standard:** DSC is implemented as an ERC20 token using OpenZeppelin contracts.
- **Oracle Library (`OracleLib`)**: Prevents using stale price feed data.
- **Tests & Fuzzing:** Comprehensive testing with Foundry, including fuzz testing.
- **Deployment Scripts:** Automated deployment using Foundry scripts.

## Installation

### Prerequisites
Ensure you have the following installed:
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (for testing and deployment)
- [Node.js & npm](https://nodejs.org/) (for additional package management if needed)
- [Git](https://git-scm.com/) (for version control)

### Setup

1. **Clone the repository**:
   ```sh
   git clone https://github.com/yourusername/dsc-engine.git
   cd dsc-engine
   ```

2. **Install Foundry**:
   ```sh
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

3. **Install Dependencies**:
   ```sh
   forge install openzeppelin/contracts@latest
   forge install smartcontractkit/chainlink-brownie-contracts@latest
   ```

## Usage

### Running Tests
To run all tests, including unit tests and fuzzing:
```sh
forge test
```

For verbose output:
```sh
forge test -vvv
```

### Deploying Contracts
You can deploy the contracts using Foundry scripts:
```sh
forge script script/DeployDSCEngine.s.sol --fork-url <RPC_URL> --broadcast
```
Replace `<RPC_URL>` with your Ethereum node provider (e.g., Alchemy, Infura).

### Fuzz Testing
Fuzz tests ensure stability against unexpected inputs. Run fuzz tests with:
```sh
forge test --fuzz-runs 500
```

## Smart Contracts Overview

### **DSC Engine (`DSCEngine.sol`)**
The core contract responsible for managing deposits, minting, redemptions, and liquidations.

- `depositCollateral()` - Deposits WETH/WBTC as collateral.
- `mintDSC()` - Mints DSC against collateral.
- `redeemCollateral()` - Withdraws collateral (if healthy).
- `liquidate()` - Liquidates undercollateralized positions.
- `_healthFactor()` - Computes if an account can be liquidated.

### **DSC Token (`DSC.sol`)**
- Implements the ERC20 standard using OpenZeppelin.
- Used as the stablecoin minted in the system.

### **Oracle Library (`OracleLib.sol`)**
- Prevents stale Chainlink oracle price data from being used.
- Ensures reliable pricing before minting or liquidating.

## Contributing
Feel free to fork this repository, submit issues, and open pull requests!

## License
This project is licensed under the MIT License.
