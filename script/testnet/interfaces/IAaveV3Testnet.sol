// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPool} from "../../../src/interfaces/aave/IPool.sol";

/**
 * @title IAaveV3Errors
 * @notice The custom errors of Aave V3.6 (Errors library, aave-dao/aave-v3-origin tag v3.6.0, commit bcc4c77a, MIT),
 *         the release deployed on Base Sepolia (Pool revision 10, aToken and debt token revision 5).
 * @dev Declared here so the demo app's combined ABI can decode a revert raised inside Aave into its name.
 */
interface IAaveV3Errors {
    error CallerNotPoolAdmin();
    error CallerNotPoolOrEmergencyAdmin();
    error CallerNotRiskOrPoolAdmin();
    error CallerNotAssetListingOrPoolAdmin();
    error AddressesProviderNotRegistered();
    error InvalidAddressesProviderId();
    error NotContract();
    error CallerNotPoolConfigurator();
    error CallerNotAToken();
    error InvalidAddressesProvider();
    error InvalidFlashloanExecutorReturn();
    error ReserveAlreadyAdded();
    error NoMoreReservesAllowed();
    error EModeCategoryReserved();
    error ReserveLiquidityNotZero();
    error FlashloanPremiumInvalid();
    error InvalidReserveParams();
    error InvalidEmodeCategoryParams();
    error CallerMustBePool();
    error InvalidMintAmount();
    error InvalidBurnAmount();
    error InvalidAmount();
    error ReserveInactive();
    error ReserveFrozen();
    error ReservePaused();
    error BorrowingNotEnabled();
    error NotEnoughAvailableUserBalance();
    error InvalidInterestRateModeSelected();
    error HealthFactorLowerThanLiquidationThreshold();
    error CollateralCannotCoverNewBorrow();
    error NoDebtOfSelectedType();
    error NoExplicitAmountToRepayOnBehalf();
    error UnderlyingBalanceZero();
    error HealthFactorNotBelowThreshold();
    error CollateralCannotBeLiquidated();
    error SpecifiedCurrencyNotBorrowedByUser();
    error InconsistentFlashloanParams();
    error BorrowCapExceeded();
    error SupplyCapExceeded();
    error DebtCeilingExceeded();
    error UnderlyingClaimableRightsNotZero();
    error VariableDebtSupplyNotZero();
    error LtvValidationFailed();
    error InconsistentEModeCategory();
    error PriceOracleSentinelCheckFailed();
    error AssetNotBorrowableInIsolation();
    error ReserveAlreadyInitialized();
    error UserInIsolationModeOrLtvZero();
    error InvalidLtv();
    error InvalidLiquidationThreshold();
    error InvalidLiquidationBonus();
    error InvalidDecimals();
    error InvalidReserveFactor();
    error InvalidBorrowCap();
    error InvalidSupplyCap();
    error InvalidLiquidationProtocolFee();
    error InvalidDebtCeiling();
    error InvalidReserveIndex();
    error AclAdminCannotBeZero();
    error InconsistentParamsLength();
    error ZeroAddressNotValid();
    error InvalidExpiration();
    error InvalidSignature();
    error OperationNotSupported();
    error DebtCeilingNotZero();
    error AssetNotListed();
    error InvalidOptimalUsageRatio();
    error UnderlyingCannotBeRescued();
    error AddressesProviderAlreadyAdded();
    error PoolAddressesDoNotMatch();
    error SiloedBorrowingViolation();
    error ReserveDebtNotZero();
    error FlashloanDisabled();
    error InvalidMaxRate();
    error WithdrawToAToken();
    error SupplyToAToken();
    error Slope2MustBeGteSlope1();
    error CallerNotRiskOrPoolOrEmergencyAdmin();
    error LiquidationGraceSentinelCheckFailed();
    error InvalidGracePeriod();
    error InvalidFreezeState();
    error InvalidLtvzeroState();
    error NotBorrowableInEMode();
    error CallerNotUmbrella();
    error ReserveNotInDeficit();
    error MustNotLeaveDust();
    error UserCannotHaveDebt();
    error SelfLiquidation();
    error CallerNotPositionManager();
    error InvalidCollateralInEmode(address reserve, uint256 categoryId);
    error InvalidDebtInEmode(address reserve, uint256 categoryId);
    error MustBeEmodeCollateral(address reserve, uint256 categoryId);
}

/**
 * @title IAaveV3Testnet
 * @notice The Aave V3.6 Pool reads the testnet tooling and the demo app need beyond the protocol's IPool, plus Aave's
 *         errors.
 */
interface IAaveV3Testnet is IPool, IAaveV3Errors {
    /**
     * @dev DataTypes.ReserveDataLegacy of Aave V3.6. Rates and indexes are rays (1e27).
     */
    struct ReserveDataLegacy {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveDataLegacy memory);
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
    function getEModeCategoryCollateralBitmap(uint8 id) external view returns (uint128);
    function getEModeCategoryBorrowableBitmap(uint8 id) external view returns (uint128);
    function getUserEMode(address user) external view returns (uint256);
}

/**
 * @title IAaveScaledBalanceToken
 * @notice aToken and variable debt token reads: balances are scaled balances times the reserve index.
 */
interface IAaveScaledBalanceToken {
    function scaledBalanceOf(address user) external view returns (uint256);
    function scaledTotalSupply() external view returns (uint256);
    function balanceOf(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/**
 * @title IAaveOracle
 * @notice Aave's price oracle. On Base Sepolia it reads the Chainlink ETH/USD feed for WETH.
 */
interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function getSourceOfAsset(address asset) external view returns (address);
    function BASE_CURRENCY_UNIT() external view returns (uint256);
}
