//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleLib} from "../test/libraries/OracleLib.sol";

/*
* @title DSCEngine
* @author Daksh Mane

*@notice The system is designed to be as minimal as possible , have tokens to maintain 
* This system regulates the stablecoin with properties :
* - Exogenously Collateralized
* - Dollar pegged
* - Algorithmically Stable 

* This contract handles the logic for minting and redeeming the DSC token , as well
* as depositing and withdrawing the collateral tokens.
* @notice This contract is based on MakerDAO DSS system
*/
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine_TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////
    // Types
    ///////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////
    // State Variables
    ///////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //10% bonus
    DecentralizedStableCoin private immutable i_dsc;

    //@dev Mapping of the collateral deposited by the user
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    //@dev Mapping of the DSC minted by the user
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    //@dev Mapping of the price feed for the collateral token
    mapping(address token => address pricefeed) private s_priceFeeds;

    ///////////////////
    // Events
    ///////////////////
    event HealthFactorIsOk(address USER);
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    ///////////////////
    // Modifiers
    ///////////////////
    modifier MorethanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowed();
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }
        uint256 addresslength = tokenAddresses.length;
        for (uint256 i = 0; i < addresslength; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////
    // External Functions
    ///////////////////

    /*
     * @param tokenCollateralAddress : The ERC20 token address of collateral user wants to deposit
     * @param amountCollateral : The amount of collateral user wants to deposit
     * @param amountDscToMint : The amount of DSC user wants to mint
     * @notice This function allows the user to deposit the collateral and mint the DSC token in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /* 
    * @param tokenCollateralAddress : The ERC20 token address of collateral user wants to redeem
    * @param amountCollateral : The amount of collateral user wants to redeem
    * @param amountDscToBurn : The amount of DSC user wants to burn
    * @notice This function allows the user to redeem the collateral and burn the DSC token in one transaction
    
    */

    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);

        redeemCollateral(tokenCollateralAddress, amountCollateral);

        //redeem collateral already check the health factor ...
    }

    //$100 ETH -> $20 DSC
    // 1. burn DSC first ..
    // 2 . redeem ETH  //2 transactions needed ...

    //In order for the user to redeem the collateral first we need
    //to check if the user's health factor should be greater than 1 ..

    /*
    * @param tokenCollateralAddress : The ERC20 token address of collateral user wants to redeem
    * @param amountCollateral : The amount of collateral user wants to redeem
    * @notice This function allows the user to redeem the collateral
    * @notice If user has DSCMinted , user wont be able to redeem until he burns the DSC

    */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public MorethanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertHealthFactorIsBroken(msg.sender);
    }

    /* 
    * @dev User can use this if nervous about being liquidated and burn his DSC but keep your collateral in 
    
    */

    function burnDsc(uint256 amount) public MorethanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertHealthFactorIsBroken(msg.sender); //dont know if we actually need this ..
    }

    //check if the collateralvalue > DCS amt ..

    ////////////////////////////////////////////////////////////////////////////////
    ////////these functions will check if the dsc doesnt gets mor than the collateral if so then the user funds
    // gets liquidated ....
    ///////////////////////////////////////////////////////////////////////////////////

    function _revertHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR)
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        return
            (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    )
        external
        MorethanZero(debtToCover)
        isAllowedToken(collateral)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(msg.sender);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR)
            emit HealthFactorIsOk(user);

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );

        //Liquidator should get a 10% bonus for liquidating the user

        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / 100;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;

        _redeemCollateral(
            collateral,
            totalCollateralToRedeem,
            user,
            msg.sender
        );
        // Burn DSC equal to debtToCover

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingUserHealthFactor)
            revert DSCEngine__HealthFactorNotImproved();

        _revertHealthFactorIsBroken(msg.sender);
    }

    ///////////////////
    // Public Functions
    ///////////////////

    function mintDsc(
        uint256 amountDscToMint
    ) public MorethanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        if (!minted) revert DSCEngine__MintFailed();

        //we need to check if the user doesnt mints too much of the DSC token than the
        // collateral so we need a internal function which will have the equation to check ...
    }

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        MorethanZero(amountCollateral)
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

        if (!success) revert DSCEngine__TransferFailed();

        // _revertHealthFactorIsBroken(msg.sender);
    }

    ///////////////////
    // Private Functions
    ///////////////////

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );

        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) revert DSCEngine__TransferFailed();
    }

    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );

        if (!success) revert DSCEngine__TransferFailed();

        i_dsc.burn(amountDscToBurn);
    }

    ////////////////////////////////////
    // External & public view functions
    ////////////////////////////////////

    function getwethPrice(address token) external view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        (totalDscMinted, collateralValueInUSD) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) public view returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getAddtionalFeedPrecision() external view returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external view returns (uint256) {
        return PRECISION;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        //total dsc minted
        //total collateral value

        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        return calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getAccountCollateralValueInUSD(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token , get the amount they have deposiyed and map it ot the price to get
        // the total value of the collateral

        uint256 i_collateralTokensLength = s_collateralTokens.length;

        for (uint256 i = 0; i < i_collateralTokensLength; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUSD(user);
    }
    function _healthFactor(address user) private view returns (uint256) {
        //total dsc minted
        //total collateral value

        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        return calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    // we want to burn DSC "debt"
    //and take their collateral
}
