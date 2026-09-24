// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {UniswapV4Adapter} from "../../src/adapters/UniswapV4Adapter.sol";
import {IPool} from "../../src/interfaces/aave/IPool.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MockVariableDebtToken} from "../mocks/MockVariableDebtToken.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/**
 * @title AaveAdapterHarness
 * @notice Exposes the internal AaveAdapter library functions.
 */
contract AaveAdapterHarness {
    function supply(address pool, address asset, uint256 amount) external {
        AaveAdapter.supply(pool, asset, amount);
    }

    function withdraw(address pool, address asset, uint256 amount) external returns (uint256) {
        return AaveAdapter.withdraw(pool, asset, amount);
    }

    function borrow(address pool, address asset, uint256 amount) external returns (uint256) {
        return AaveAdapter.borrow(pool, asset, amount);
    }

    function repay(address pool, address asset, uint256 amount) external returns (uint256) {
        return AaveAdapter.repay(pool, asset, amount);
    }
}

/**
 * @title UniswapV4AdapterHarness
 * @notice Minimal UniswapV4Adapter that records what it sees inside the flash loan callback.
 */
contract UniswapV4AdapterHarness is UniswapV4Adapter {
    uint256 public balanceInCallback;
    uint256 public outstandingInCallback;
    bytes public dataInCallback;

    constructor(address poolManager) UniswapV4Adapter(poolManager) {}

    function borrow(Currency currency, uint256 amount, bytes memory data) external {
        flashLoan(currency, amount, data);
    }

    function outstanding() external view returns (uint256) {
        return _flashLoanOutstanding();
    }

    function _onFlashLoan(Currency currency, uint256, bytes memory data) internal override {
        balanceInCallback = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        outstandingInCallback = _flashLoanOutstanding();
        dataInCallback = data;
    }
}

/**
 * @title ShortSettlePoolManager
 * @notice PoolManager mock whose settle() reports nothing paid, to hit FlashLoanRepaymentFailed.
 */
contract ShortSettlePoolManager is MockPoolManager {
    function settle() public pure override returns (uint256) {
        return 0;
    }
}

contract AdaptersTest is Test {
    MockWETH internal weth;
    MockAavePool internal pool;
    MockAToken internal aToken;
    MockVariableDebtToken internal debtToken;
    AaveAdapterHarness internal aave;

    function setUp() public {
        weth = new MockWETH();
        pool = new MockAavePool();
        aToken = new MockAToken("Aave WETH", "aWETH", address(pool));
        debtToken = new MockVariableDebtToken("Aave Variable Debt WETH", "variableDebtWETH", address(pool));
        pool.setAToken(address(weth), aToken);
        pool.setDebtToken(address(weth), debtToken);
        pool.setPrimaryAsset(address(weth));
        weth.mint(address(pool), 1_000 ether);

        aave = new AaveAdapterHarness();
        weth.mint(address(aave), 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              AAVE ADAPTER
    //////////////////////////////////////////////////////////////*/

    /// @notice Zero amounts return early without calling the pool.
    function test_AaveAdapter_ZeroAmounts_DoNotCallPool() public {
        vm.expectCall(address(pool), abi.encodeWithSelector(IPool.supply.selector), 0);
        vm.expectCall(address(pool), abi.encodeWithSelector(IPool.withdraw.selector), 0);
        vm.expectCall(address(pool), abi.encodeWithSelector(IPool.borrow.selector), 0);
        vm.expectCall(address(pool), abi.encodeWithSelector(IPool.repay.selector), 0);

        aave.supply(address(pool), address(weth), 0);
        assertEq(aave.withdraw(address(pool), address(weth), 0), 0, "withdraw(0) returns 0");
        assertEq(aave.borrow(address(pool), address(weth), 0), 0, "borrow(0) returns 0");
        assertEq(aave.repay(address(pool), address(weth), 0), 0, "repay(0) returns 0");
    }

    /// @notice supply approves exactly the amount, supplies on behalf of the caller and leaves no allowance.
    function test_AaveAdapter_Supply() public {
        vm.expectCall(address(pool), abi.encodeCall(IPool.supply, (address(weth), 4 ether, address(aave), 0)));
        aave.supply(address(pool), address(weth), 4 ether);

        assertEq(aToken.balanceOf(address(aave)), 4 ether, "aTokens minted to the caller");
        assertEq(weth.balanceOf(address(aave)), 6 ether, "Asset transferred to the pool");
        assertEq(weth.allowance(address(aave), address(pool)), 0, "Allowance fully used");
    }

    /// @notice withdraw returns the amount the pool actually withdrew.
    function test_AaveAdapter_Withdraw_ReturnsWithdrawnAmount() public {
        aave.supply(address(pool), address(weth), 4 ether);

        assertEq(aave.withdraw(address(pool), address(weth), 1 ether), 1 ether, "Exact withdrawal");
        // MockAavePool caps the withdrawal at the balance, like Aave does for type(uint256).max
        assertEq(aave.withdraw(address(pool), address(weth), type(uint256).max), 3 ether, "Full withdrawal returns the balance");
        assertEq(aToken.balanceOf(address(aave)), 0, "No aTokens left");
    }

    /// @notice borrow uses variable rate mode 2 and returns the requested amount.
    function test_AaveAdapter_Borrow_UsesVariableRate() public {
        aave.supply(address(pool), address(weth), 4 ether);

        vm.expectCall(address(pool), abi.encodeCall(IPool.borrow, (address(weth), 2 ether, 2, 0, address(aave))));
        assertEq(aave.borrow(address(pool), address(weth), 2 ether), 2 ether, "Returns the borrowed amount");
        assertEq(debtToken.balanceOf(address(aave)), 2 ether, "Variable debt minted");
    }

    /// @notice repay returns the amount the pool actually repaid, capped at the debt.
    function test_AaveAdapter_Repay_ReturnsRepaidAmount() public {
        aave.supply(address(pool), address(weth), 4 ether);
        aave.borrow(address(pool), address(weth), 2 ether);

        vm.expectCall(address(pool), abi.encodeCall(IPool.repay, (address(weth), 0.5 ether, 2, address(aave))));
        assertEq(aave.repay(address(pool), address(weth), 0.5 ether), 0.5 ether, "Partial repayment");
        assertEq(aave.repay(address(pool), address(weth), 5 ether), 1.5 ether, "Repayment capped at the remaining debt");
        assertEq(debtToken.balanceOf(address(aave)), 0, "Debt cleared");
    }

    /*//////////////////////////////////////////////////////////////
                           UNISWAP V4 ADAPTER
    //////////////////////////////////////////////////////////////*/

    /// @notice flashLoan runs the callback with the borrowed funds and repays the PoolManager in full.
    function test_UniswapV4Adapter_FlashLoan_RepaysAndTracksOutstanding() public {
        MockPoolManager manager = new MockPoolManager();
        weth.mint(address(manager), 100 ether);
        UniswapV4AdapterHarness adapter = new UniswapV4AdapterHarness(address(manager));

        adapter.borrow(Currency.wrap(address(weth)), 7 ether, abi.encode(uint256(42)));

        assertEq(adapter.balanceInCallback(), 7 ether, "Borrowed funds available in the callback");
        assertEq(adapter.outstandingInCallback(), 7 ether, "Loan recorded as outstanding during the callback");
        assertEq(abi.decode(adapter.dataInCallback(), (uint256)), 42, "User data forwarded");
        assertEq(adapter.outstanding(), 0, "Outstanding cleared after repayment");
        assertEq(weth.balanceOf(address(manager)), 100 ether, "PoolManager repaid in full");
        assertEq(weth.balanceOf(address(adapter)), 0, "Adapter keeps nothing");
    }

    /// @notice unlockCallback rejects callers other than the PoolManager.
    function test_UniswapV4Adapter_UnlockCallback_RevertIfNotPoolManager() public {
        UniswapV4AdapterHarness adapter = new UniswapV4AdapterHarness(address(new MockPoolManager()));

        vm.expectRevert(UniswapV4Adapter.CallbackUnauthorized.selector);
        adapter.unlockCallback(abi.encode(Currency.wrap(address(weth)), 1 ether, bytes("")));
    }

    /// @notice A settle() result different from the loan amount reverts with FlashLoanRepaymentFailed.
    function test_UniswapV4Adapter_RevertIfSettleDoesNotMatch() public {
        ShortSettlePoolManager manager = new ShortSettlePoolManager();
        weth.mint(address(manager), 100 ether);
        UniswapV4AdapterHarness adapter = new UniswapV4AdapterHarness(address(manager));

        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.FlashLoanRepaymentFailed.selector, 0, 7 ether));
        adapter.borrow(Currency.wrap(address(weth)), 7 ether, bytes(""));
    }

    /// @notice The flash loan reverts if the PoolManager cannot fund it.
    function test_UniswapV4Adapter_RevertIfPoolManagerLacksLiquidity() public {
        MockPoolManager manager = new MockPoolManager();
        weth.mint(address(manager), 1 ether);
        UniswapV4AdapterHarness adapter = new UniswapV4AdapterHarness(address(manager));

        vm.expectRevert();
        adapter.borrow(Currency.wrap(address(weth)), 2 ether, bytes(""));
    }
}
