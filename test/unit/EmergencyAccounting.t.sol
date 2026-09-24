// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBearingVault} from "../../src/vaults/YieldBearingVault.sol";
import {WETHLoopStrategy} from "../../src/strategies/WETHLoopStrategy.sol";
import {AaveSimpleLendingStrategy} from "../../src/strategies/AaveSimpleLendingStrategy.sol";
import {StrategyTestBase} from "../utils/StrategyTestBase.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";

/**
 * @title EmergencyAccountingTestBase
 * @notice Regression tests for review finding 1: idle assets held by a strategy were not counted in totalAssets().
 * @dev Before the fix, a user redeeming after an emergency divest received about 1,000 wei for a 1 WETH deposit.
 */
abstract contract EmergencyAccountingTestBase is StrategyTestBase {
    /// @notice After an emergency divest, the only depositor redeems their proportional share of equity.
    function test_EmergencyDivest_RedeemReturnsProportionalEquity() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _makeUnhealthy(strategy);
        assertFalse(strategy.checkHealth(), "Emergency divest should run");

        uint256 expected = vault.balanceOf(alice) * _rawEquity(vault, address(strategy)) / vault.totalSupply();

        // ============ ACT ============
        uint256 received = _redeemAll(vault, alice);

        // ============ ASSERT ============
        assertApproxEqAbs(received, expected, 2, "Redeem should pay the proportional share of equity");
        assertApproxEqAbs(received, 1 ether, 10, "Emergency divest with a zero-fee flash loan should preserve the deposit");
    }

    /// @notice Two depositors redeem in sequence after an emergency divest and each receives a pro rata share.
    function test_EmergencyDivest_MultipleUsersRedeemProRata() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        _deposit(vault, bob, 2 ether);
        _makeUnhealthy(strategy);
        strategy.checkHealth();

        // ============ ACT & ASSERT ============
        uint256 expectedAlice = vault.balanceOf(alice) * _rawEquity(vault, address(strategy)) / vault.totalSupply();
        assertApproxEqAbs(_redeemAll(vault, alice), expectedAlice, 2, "Alice pro rata share");

        uint256 expectedBob = vault.balanceOf(bob) * _rawEquity(vault, address(strategy)) / vault.totalSupply();
        assertApproxEqAbs(_redeemAll(vault, bob), expectedBob, 2, "Bob pro rata share");
        assertApproxEqAbs(expectedBob, 2 ether, 20, "Bob keeps his deposit");
    }

    /// @notice WETHLoopStrategy.totalAssets() equals collateral + idle WETH - debt, before and after an emergency divest.
    function test_WethLoop_TotalAssetsCountsIdleAssets() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);

        // ============ ACT ============
        _makeUnhealthy(strategy);
        strategy.checkHealth();

        // ============ ASSERT ============
        uint256 collateral = IERC20(aToken).balanceOf(address(strategy));
        uint256 idle = weth.balanceOf(address(strategy));
        uint256 debt = IERC20(debtToken).balanceOf(address(strategy));
        assertGt(idle, 0, "Emergency divest should leave idle WETH");
        assertEq(strategy.totalAssets(), collateral + idle - debt, "totalAssets must include idle WETH");
    }

    /// @notice AaveSimpleLendingStrategy.totalAssets() includes asset tokens held directly by the strategy.
    function test_AaveSimple_TotalAssetsCountsIdleAssets() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, AaveSimpleLendingStrategy strategy) = _deployAaveSimple();
        _deposit(vault, alice, 1 ether);

        // ============ ACT ============
        _fund(address(strategy), 0.5 ether);

        // ============ ASSERT ============
        uint256 expected = IERC20(aToken).balanceOf(address(strategy)) + 0.5 ether;
        assertEq(strategy.totalAssets(), expected, "totalAssets must include idle assets");
    }

    /// @notice A donation to an empty strategy does not dilute the first depositor (strategy decimals offset).
    function test_Donation_BeforeFirstDeposit_DoesNotDiluteDepositor() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _fund(address(strategy), 1 ether);

        // ============ ACT ============
        uint256 shares = _deposit(vault, alice, 1 ether);

        // ============ ASSERT ============
        uint256 value = vault.previewRedeem(shares);
        assertGe(value, 1 ether - 1 ether / 1e6, "Depositor should keep at least 99.9999% of the deposit");
    }
}

/**
 * @title ObservingAavePool
 * @notice MockAavePool that records the strategy's totalAssets() while a flash loan is in progress.
 */
contract ObservingAavePool is MockAavePool {
    bool public armed;
    uint256 public observedTotalAssets;

    function arm() external {
        armed = true;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) public override {
        if (armed) {
            armed = false;
            observedTotalAssets = WETHLoopStrategy(onBehalfOf).totalAssets();
        }
        super.supply(asset, amount, onBehalfOf, referralCode);
    }
}

contract EmergencyAccountingMockTest is EmergencyAccountingTestBase {
    function _useFork() internal pure override returns (bool) {
        return false;
    }

    function setUp() public {
        _setUpProtocol(new ObservingAavePool());
    }

    /// @notice totalAssets() does not count the borrowed flash loan as equity while the loan is outstanding.
    function test_TotalAssets_NoDoubleCountingDuringFlashLoan() public {
        // ============ ARRANGE ============
        (YieldBearingVault vault, WETHLoopStrategy strategy) = _deployWethLoop();
        _deposit(vault, alice, 1 ether);
        uint256 equityBefore = strategy.totalAssets();

        // ============ ACT ============
        ObservingAavePool(address(mockPool)).arm();
        _deposit(vault, bob, 2 ether);

        // ============ ASSERT ============
        // Inside the callback the strategy holds bob's 2 WETH plus the 18 WETH flash loan, and owes the flash loan
        assertEq(ObservingAavePool(address(mockPool)).observedTotalAssets(), equityBefore + 2 ether, "Flash loan must not count as equity");
    }
}
