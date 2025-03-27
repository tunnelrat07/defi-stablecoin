// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions
pragma solidity ^0.8.18;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/// @title DSC Engine
/// @author Tunnel Rat
/// This system is designed to be as minimal as possible
/// and have the system maintain a 1 token = $1.00 peg
/// This stable coin has the properties
// - Exogenous collateral
// - Dollar pegged
// - Algorithmically stable
// It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC
/// Our DSC system should always be "overcollateralized". At no point should the value of all the collateral <= the $ backed value of all the DSC
/// @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC , as well as depositing and withdrawing collateral. This contract is very loosely based on MakerDAO DSS (DAI) system

contract DSCEngine is ReentrancyGuard {
    ////////////////
    ////Errors  ////
    ////////////////
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine_HealthFactorOK();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine_TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();

    ////////////////
    ////Types  ////
    ////////////////
    using OracleLib for AggregatorV3Interface;

    ////////////////
    ////State Variables  ////
    ////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% liquidation bonus to the liquidator
    uint256 private constant LIQUIDATION_PRECISION = 100;
    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeeds
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    DecentralizedStableCoin private immutable i_dsc;
    address[] s_collateralTokens;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    ////////////////
    ////Events  ////
    ////////////////

    event CollateralDeposited(
        address indexed user,
        address indexed tokenCollateralAddress,
        uint256 indexed amountCollateral
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed tokenCollateralAddress,
        uint256 amountCollateral
    );

    ////////////////
    ////Modifier////
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        // token address does not exist in our mapping
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ////////////////
    ////Functions////
    ////////////////
    constructor(
        address[] memory tokenAddress,
        address[] memory priceFeedAddress,
        address dscAddress
    ) {
        // USD priceFeed
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        // For eg - ETH/USD , BTC/USD
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    ////External Functions////
    //////////////////////////

    /**
     *
     * @param tokenCollateralAddress - > Address of token to deposit as collateral
     * @param amountCollateral -> amount of collateral to deposit
     * @param amountDscToMint -> amount of Decentralized Stable Coin to mint
     * @notice This function will deposit your collateral and mint Dsc in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral((tokenCollateralAddress), amountCollateral);
        mintDSC(amountDscToMint);
    }

    /*
     * Follows CEI pattern
     */

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress -> address of the token collateral to redeem
     * @param amountCollateral -> amount of collateral to redeem
     * @param amountDscToBurn -> amount of Dsc to burn
     * This function burns Dsc and redeems underlying collateral in one single transaction
     */

    function redeemCollateralForDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral already checks the health factor
    }

    // in order to redeem collateral
    // 1. Health factor must be > 1 , AFTER the collateral is pulled
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param amountDscToMint -> The amount of Decentralized stable coin to mint
     * @notice they must have more collateral than the minimum threshold
     */
    function mintDSC(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC , $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountToBurn) public moreThanZero(amountToBurn) {
        _burnDsc(amountToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
        // this wont be needed tho
    }

    // If we do start nearing under-collateralization , we need someone to liquidate positions
    // If someone is almost undercollateralized we will pay to liquidate them
    // for example -> $75 ETH backing -> $50 Dsc
    // Liquidator takes $75 and burns off $50
    /**
     * @param collateral -> ERC20 collateral address to liquidate from the user
     * @param user -> The user who has broken _healthFactor. Their health factor should be below MIN_HEALTH_FACTOR
     * @param debtToCover -> The amount of DSC you want to burn to improve user's health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will almost be 200% overcollateralized for this to work
     * @notice A known bug would be if the protocol was <100% overcollateralized , then we wouldnt be able to incentivize the liquidators
     * For eg -> price of the collateral plummeted before anyone could be liquidated
     * Follows CEI
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        // need to check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOK();
        }
        // We wanna burn their DSC
        // And take their collateral
        // Bad User : $140 ETH , $100 DSC
        // DebtToCover -> $100
        // $100 Dsc == how much ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        // And we wanna give them a 10% bonus
        // We are giving the liquidator of wEth for 100 DSC
        // We should implement a feature to liquidate in the event that protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;

        _redeemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToRedeem
        );
        // now we need to burn the Dsc
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        (totalDscMinted, collateralValueInUSD) = _getAccountInformation(user);
    }

    ////////////////////////////////////////////
    //// Private and Internal View Functions////
    ////////////////////////////////////////////

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUSD = getCollateralValue(user);
        return (totalDscMinted, collateralValueInUSD);
    }

    // Returns how close to liquidation a user is
    // If a user goes below 1 , then they can get liquidated
    function _healthFactor(address user) private view returns (uint256) {
        // totalDscMinted & totalCollateralValue
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUSD
        ) = _getAccountInformation(user);

        // mintedToken value nearly equals $1.00
        // hence $ value of minted Dsc nealry = number of Dsc
        /* return (collateralValueInUSD / totalDscMinted); */
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((collateralAdjustedForThreshold * PRECISION) / totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor (Do they have enough collateral)
        // 2. Revert If they dont
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////////
    //// Public and External  View Functions////
    ////////////////////////////////////////////

    function getCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through Each collateral token that the user has deposited, get the amount that they have deposited , and map it to the price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            // now that we have the amount we wanna get the USD value of that
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        // lets get the priceFeed
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.stalePriceCheck();
        // 1ETH = $1000
        // then the returned value of the Data Feed will be 1000*1e8
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        // price of token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.stalePriceCheck();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        // calculate health factor
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    /** @dev  Low level internal function
     * do not call unless a function calling this is checking for the _healthFactor being broken
     *
     */
    function _burnDsc(
        uint256 amountToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DscMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, dscFrom, amountToBurn);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        // we're just burning our DSC , so it wont affect our health factor
        i_dsc.burn(amountToBurn);
    }
}
