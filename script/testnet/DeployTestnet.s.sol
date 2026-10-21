// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {DemoOperator} from "./DemoOperator.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {IAaveV3Testnet, IAaveScaledBalanceToken, IAaveOracle} from "./interfaces/IAaveV3Testnet.sol";

/**
 * @title DeployTestnet
 * @notice Public testnet deployment of the demo vault (Base Sepolia by default): a YieldBearingVault over the canonical
 *         WETH with a WETHLoopStrategy on the real Aave V3 pool and Uniswap V4 PoolManager of the chain, a seed position
 *         that nobody can withdraw, and DemoOperator holding the owner and admin roles so visitors can join the
 *         whitelist and run the emergency cycle.
 * @dev The repository has no Deploy.s.sol. The strategy parameters are the ones the test suite uses
 *      (test/utils/StrategyTestBase.sol): 10x, E-Mode category 1, minHealthFactor 1.02, targetHealthFactor 1.05.
 *      The performance fee is 10% to the deployer.
 *
 *      Before anything is sent the run checks, with view calls, that every dependency has code and matches the Aave
 *      reserve, that the reserve and the E-Mode category accept the leverage, and that the borrow cap, the supply cap
 *      and the PoolManager's WETH leave room for the seed. Forge then simulates the whole broadcast block, so the seed
 *      deposit goes through the real code path (vault, strategy, flash loan, Aave supply and borrow, health factor
 *      check) before any transaction leaves. After the broadcast block, still in simulation only, a smoke test drives
 *      the deployment the way the demo app does and reverts its own state changes. On a real broadcast the run writes
 *      the deployment file the app reads; a dry run leaves it alone.
 *
 *      Nothing in the run carries a price with a short staleness window, so there is no separate time-sensitive script.
 *
 *      Usage (Base Sepolia):
 *        forge script script/testnet/DeployTestnet.s.sol --rpc-url https://sepolia.base.org \
 *          --account <keystore> --broadcast
 *      Optional env: SEED_ASSETS (wei, default 0.1 WETH), DEPLOYMENT_FILE, and on chains other than Base Sepolia and
 *      its local fork (31337): WETH, AAVE_POOL, A_TOKEN, VARIABLE_DEBT_TOKEN, AAVE_ORACLE, POOL_MANAGER.
 */
contract DeployTestnet is Script {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Base Sepolia, checked on 21 Oct 2026 against the Aave address book (AaveV3BaseSepolia.sol), the Uniswap V4
     *      deployments page and the chain itself (PoolAddressesProvider.getPool(), getReserveData(WETH)).
     */
    address internal constant BASE_SEPOLIA_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_SEPOLIA_AAVE_POOL = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    address internal constant BASE_SEPOLIA_AWETH = 0x73a5bB60b0B0fc35710DDc0ea9c407031E31Bdbb;
    address internal constant BASE_SEPOLIA_VARIABLE_DEBT_WETH = 0x562abf6562d6A2b165aDa02b5946bc3E7b4dD653;
    address internal constant BASE_SEPOLIA_AAVE_ORACLE = 0x943b0dE18d4abf4eF02A85912F8fc07684C141dF;
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    /**
     * @dev Chain id of the local rehearsal: anvil forking Base Sepolia (app/scripts/local-chain.sh).
     */
    uint256 internal constant LOCAL_FORK_CHAIN_ID = 31_337;

    /**
     * @dev Strategy parameters of the test suite (test/utils/StrategyTestBase.sol).
     */
    uint8 internal constant TARGET_LEVERAGE = 10;
    uint256 internal constant MIN_HEALTH_FACTOR = 1.02e18;
    uint256 internal constant TARGET_HEALTH_FACTOR = 1.05e18;
    uint8 internal constant E_MODE_CATEGORY = 1;

    /**
     * @dev The vault constructor requires exactly this initial deposit, burned as dead shares.
     */
    uint256 internal constant INITIAL_DEPOSIT = 1000;

    uint16 internal constant PROTOCOL_FEE_BPS = 1000;

    /**
     * @dev Seed deposit owned by DemoOperator, which cannot withdraw it: 0.1 WETH at 10x is 1 WETH of collateral.
     */
    uint256 internal constant DEFAULT_SEED_ASSETS = 0.1 ether;

    /**
     * @dev Deposit of the throwaway visitor in the smoke test.
     */
    uint256 internal constant SMOKE_DEPOSIT = 0.01 ether;

    uint256 internal constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MissingCode(string name, address account);
    error WiringMismatch(string name, address expected, address actual);
    error ReserveNotUsable(uint256 configuration);
    error EModeNotUsable(uint8 categoryId, uint256 ltv, uint256 liquidationThreshold);
    error ReserveNotInEMode(uint8 categoryId, uint256 reserveId);
    error BorrowCapHeadroomTooLow(uint256 headroom, uint256 required);
    error SupplyCapHeadroomTooLow(uint256 headroom, uint256 required);
    error InsufficientFlashLiquidity(uint256 available, uint256 required);
    error VaultAddressMismatch(address deployed, address expected);
    error SmokeTestFailed(string check);

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice External addresses the deployment uses.
     */
    struct Wiring {
        address weth;
        address aavePool;
        address aToken;
        address variableDebtToken;
        address aaveOracle;
        address poolManager;
    }

    /**
     * @notice What the last run deployed, for tests and the deployment file.
     */
    struct Deployment {
        YieldBearingVault vault;
        WETHLoopStrategy strategy;
        DemoOperator operator;
        uint256 deployBlock;
        uint256 seedAssets;
    }

    Deployment public deployment;

    /*//////////////////////////////////////////////////////////////
                                  RUN
    //////////////////////////////////////////////////////////////*/

    function run() external returns (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) {
        return deploy(wiring(), vm.envOr("SEED_ASSETS", DEFAULT_SEED_ASSETS));
    }

    /**
     * @notice The whole run for explicit wiring and seed, so tests can vary them without touching the environment.
     */
    function deploy(Wiring memory w, uint256 seed) public returns (YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) {
        preflight(w, seed);
        uint256 deployBlock = block.number;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        IWETH9(w.weth).deposit{value: INITIAL_DEPOSIT + seed}();

        // The constructor pulls INITIAL_DEPOSIT from the deployer, so the vault address is approved before it exists.
        // The approval is the next transaction, the vault creation the one after it.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        IERC20(w.weth).approve(predicted, INITIAL_DEPOSIT);
        vault = new YieldBearingVault(IERC20(w.weth), deployer, deployer, INITIAL_DEPOSIT);
        if (address(vault) != predicted) revert VaultAddressMismatch(address(vault), predicted);

        strategy = new WETHLoopStrategy(
            IERC20(w.weth),
            address(vault),
            w.poolManager,
            w.aavePool,
            w.aToken,
            w.variableDebtToken,
            TARGET_LEVERAGE,
            MIN_HEALTH_FACTOR,
            TARGET_HEALTH_FACTOR,
            E_MODE_CATEGORY
        );
        vault.setStrategy(strategy);

        // The fee recipient receives shares, so it must be whitelisted first
        vault.addToWhitelist(deployer);
        vault.setFeeRecipient(deployer);
        vault.setProtocolFee(PROTOCOL_FEE_BPS);

        operator = new DemoOperator(vault, strategy, deployer);
        vault.addToWhitelist(address(operator));
        if (seed > 0) {
            IERC20(w.weth).approve(address(vault), seed);
            vault.deposit(seed, address(operator));
        }

        vault.setAdmin(address(operator));
        vault.transferOwnership(address(operator));
        vm.stopBroadcast();

        deployment = Deployment({vault: vault, strategy: strategy, operator: operator, deployBlock: deployBlock, seedAssets: seed});

        _smokeTest(w, vault, strategy, operator);

        // Only on a real broadcast: a dry run must not overwrite the file with addresses never deployed
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _writeDeployment(w);

        console2.log("Vault:", address(vault));
        console2.log("Strategy:", address(strategy));
        console2.log("DemoOperator:", address(operator));
    }

    /*//////////////////////////////////////////////////////////////
                                WIRING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Base Sepolia addresses on Base Sepolia and on its local fork, each overridable; any other chain must
     *         export all six.
     */
    function wiring() public view returns (Wiring memory w) {
        bool known = block.chainid == BASE_SEPOLIA_CHAIN_ID || block.chainid == LOCAL_FORK_CHAIN_ID;
        w.weth = known ? vm.envOr("WETH", BASE_SEPOLIA_WETH) : vm.envAddress("WETH");
        w.aavePool = known ? vm.envOr("AAVE_POOL", BASE_SEPOLIA_AAVE_POOL) : vm.envAddress("AAVE_POOL");
        w.aToken = known ? vm.envOr("A_TOKEN", BASE_SEPOLIA_AWETH) : vm.envAddress("A_TOKEN");
        w.variableDebtToken = known ? vm.envOr("VARIABLE_DEBT_TOKEN", BASE_SEPOLIA_VARIABLE_DEBT_WETH) : vm.envAddress("VARIABLE_DEBT_TOKEN");
        w.aaveOracle = known ? vm.envOr("AAVE_ORACLE", BASE_SEPOLIA_AAVE_ORACLE) : vm.envAddress("AAVE_ORACLE");
        w.poolManager = known ? vm.envOr("POOL_MANAGER", BASE_SEPOLIA_POOL_MANAGER) : vm.envAddress("POOL_MANAGER");
    }

    /*//////////////////////////////////////////////////////////////
                               PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice View checks run before the broadcast block, each reverting with what is wrong.
     * @dev Checks code at every address, the aToken and debt token against the reserve, the reserve flags (active, not
     *      frozen, not paused, borrowing on), that the E-Mode category takes WETH as collateral and debt with an LTV
     *      above (L - 1) / L, and that the borrow cap, the supply cap and the PoolManager's WETH leave room for the seed
     *      at target leverage. The caps and the PoolManager balance are shared with every other user of the chain.
     */
    function preflight(Wiring memory w, uint256 seed) public view {
        _requireCode("WETH", w.weth);
        _requireCode("Aave pool", w.aavePool);
        _requireCode("aToken", w.aToken);
        _requireCode("variable debt token", w.variableDebtToken);
        _requireCode("Aave oracle", w.aaveOracle);
        _requireCode("PoolManager", w.poolManager);

        uint256 config = _checkReserve(w);
        _checkRoom(w, config, seed);
    }

    /**
     * @dev Token wiring, reserve flags and E-Mode. Returns the reserve configuration for the cap checks.
     */
    function _checkReserve(Wiring memory w) internal view returns (uint256 config) {
        IAaveV3Testnet pool = IAaveV3Testnet(w.aavePool);
        IAaveV3Testnet.ReserveDataLegacy memory reserve = pool.getReserveData(w.weth);
        if (reserve.aTokenAddress != w.aToken) revert WiringMismatch("aToken", reserve.aTokenAddress, w.aToken);
        if (reserve.variableDebtTokenAddress != w.variableDebtToken) {
            revert WiringMismatch("variable debt token", reserve.variableDebtTokenAddress, w.variableDebtToken);
        }

        config = reserve.configuration;
        bool active = (config >> 56) & 1 == 1;
        bool frozen = (config >> 57) & 1 == 1;
        bool borrowing = (config >> 58) & 1 == 1;
        bool paused = (config >> 60) & 1 == 1;
        if (!active || frozen || !borrowing || paused) revert ReserveNotUsable(config);

        IAaveV3Testnet.CollateralConfig memory eMode = pool.getEModeCategoryCollateralConfig(E_MODE_CATEGORY);
        // Borrowing (L - 1) against L of collateral needs an LTV above (L - 1) / L
        if (uint256(TARGET_LEVERAGE - 1) * BPS >= uint256(TARGET_LEVERAGE) * eMode.ltv) {
            revert EModeNotUsable(E_MODE_CATEGORY, eMode.ltv, eMode.liquidationThreshold);
        }
        uint256 collateralBitmap = pool.getEModeCategoryCollateralBitmap(E_MODE_CATEGORY);
        uint256 borrowableBitmap = pool.getEModeCategoryBorrowableBitmap(E_MODE_CATEGORY);
        if ((collateralBitmap >> reserve.id) & 1 == 0 || (borrowableBitmap >> reserve.id) & 1 == 0) {
            revert ReserveNotInEMode(E_MODE_CATEGORY, reserve.id);
        }
    }

    /**
     * @dev Room for the seed at target leverage: borrow cap, supply cap and the PoolManager's WETH. A cap of 0 means none.
     */
    function _checkRoom(Wiring memory w, uint256 config, uint256 seed) internal view {
        uint256 debtNeeded = seed * (TARGET_LEVERAGE - 1);
        uint256 unit = 10 ** ((config >> 48) & 0xFF);

        uint256 borrowCap = ((config >> 80) & ((1 << 36) - 1)) * unit;
        if (borrowCap > 0) {
            uint256 debt = IAaveScaledBalanceToken(w.variableDebtToken).totalSupply();
            uint256 headroom = borrowCap > debt ? borrowCap - debt : 0;
            if (headroom < debtNeeded) revert BorrowCapHeadroomTooLow(headroom, debtNeeded);
        }

        uint256 supplyCap = ((config >> 116) & ((1 << 36) - 1)) * unit;
        if (supplyCap > 0) {
            uint256 supplied = IAaveScaledBalanceToken(w.aToken).totalSupply();
            uint256 headroom = supplyCap > supplied ? supplyCap - supplied : 0;
            if (headroom < seed * TARGET_LEVERAGE) revert SupplyCapHeadroomTooLow(headroom, seed * TARGET_LEVERAGE);
        }

        uint256 flashLiquidity = IERC20(w.weth).balanceOf(w.poolManager);
        if (flashLiquidity < debtNeeded) revert InsufficientFlashLiquidity(flashLiquidity, debtNeeded);
    }

    function _requireCode(string memory name, address account) internal view {
        if (account.code.length == 0) revert MissingCode(name, account);
    }

    /*//////////////////////////////////////////////////////////////
                               SMOKE TEST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Simulation only, after stopBroadcast, and reverted to the post-broadcast state at the end. Reads everything the
     *      app reads, then drives the deployment as the app does: join, wrap, approve, deposit, redeem the maximum, and
     *      the emergency cycle (shock, checkHealth, restore, reinvest).
     */
    function _smokeTest(Wiring memory w, YieldBearingVault vault, WETHLoopStrategy strategy, DemoOperator operator) internal {
        uint256 snapshot = vm.snapshotState();

        // Reads the app depends on
        if (IAaveOracle(w.aaveOracle).getAssetPrice(w.weth) == 0) revert SmokeTestFailed("Aave oracle price");
        IAaveV3Testnet(w.aavePool).getReserveData(w.weth);
        IAaveV3Testnet(w.aavePool).getVirtualUnderlyingBalance(w.weth);
        IAaveScaledBalanceToken(w.aToken).scaledBalanceOf(address(strategy));
        IAaveScaledBalanceToken(w.variableDebtToken).scaledBalanceOf(address(strategy));

        // A throwaway visitor: forge rejects scripts that rely on their own ephemeral address
        address visitor = makeAddr("DeployTestnet smoke test");
        vm.deal(visitor, 1 ether);
        vm.startPrank(visitor);
        operator.join();
        IWETH9(w.weth).deposit{value: SMOKE_DEPOSIT}();
        IERC20(w.weth).approve(address(vault), SMOKE_DEPOSIT);
        if (vault.maxDeposit(visitor) == 0) revert SmokeTestFailed("maxDeposit");
        vault.deposit(SMOKE_DEPOSIT, visitor);
        vault.redeem(vault.maxRedeem(visitor), visitor, visitor);
        if (vault.balanceOf(visitor) != 0) revert SmokeTestFailed("full redeem");

        if (deployment.seedAssets >= strategy.MIN_INVEST_ASSETS()) {
            operator.shock();
            strategy.checkHealth();
            if (!vault.emergencyMode()) revert SmokeTestFailed("checkHealth after shock");
            if (IERC20(w.variableDebtToken).balanceOf(address(strategy)) != 0) revert SmokeTestFailed("emergency exit");
            operator.restore();
            operator.reinvest();
            (,,,,, uint256 healthFactor) = IAaveV3Testnet(w.aavePool).getUserAccountData(address(strategy));
            if (healthFactor < strategy.targetHealthFactor()) revert SmokeTestFailed("reinvest");
        }
        vm.stopPrank();

        vm.revertToState(snapshot);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT FILE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Where the deployment file lives: DEPLOYMENT_FILE, or the app's file for this chain id.
     */
    function deploymentFile() public view returns (string memory) {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        return vm.envOr("DEPLOYMENT_FILE", defaultPath);
    }

    /**
     * @dev Writes the addresses the app needs. Every parameter the app shows is read from the chain.
     */
    function _writeDeployment(Wiring memory w) internal {
        Deployment memory d = deployment;
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployBlock", d.deployBlock);
        vm.serializeAddress(root, "vault", address(d.vault));
        vm.serializeAddress(root, "strategy", address(d.strategy));
        vm.serializeAddress(root, "operator", address(d.operator));
        vm.serializeAddress(root, "weth", w.weth);
        vm.serializeAddress(root, "aavePool", w.aavePool);
        vm.serializeAddress(root, "aToken", w.aToken);
        vm.serializeAddress(root, "variableDebtToken", w.variableDebtToken);
        vm.serializeAddress(root, "aaveOracle", w.aaveOracle);
        vm.serializeAddress(root, "poolManager", w.poolManager);
        // As a string: wei amounts do not fit a JavaScript number exactly
        root = vm.serializeString(root, "seedAssets", vm.toString(d.seedAssets));
        vm.writeJson(root, deploymentFile());
    }
}
