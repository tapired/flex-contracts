// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IStrategy} from "../src/allocator/interfaces/IStrategy.sol";
import {ILender} from "../src/lender/interfaces/ILender.sol";

import {IAuction} from "./interfaces/IAuction.sol";
import {IDutchDesk} from "./interfaces/IDutchDesk.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";

import "../script/DeployAllocator.s.sol";

import "forge-std/Test.sol";

contract AllocatorTests is DeployAllocator, Test {

    // Contracts
    ERC20 public asset;
    IStrategy public strategy;
    ILender public constant LENDER = ILender(0xA967FcDb8a2bEF38caaB6131169c9D45be550Db0);

    // Roles
    address public user = address(1);
    address public management = address(420);
    address public keeper = address(69);
    address public performanceFeeRecipient = address(42069);

    // Fuzz bounds
    uint256 public maxFuzzAmount = 1_000_000 ether;
    uint256 public minFuzzAmount = 1_000 ether;

    uint256 public MAX_BPS = 10_000;
    uint256 public ASSET_PRECISION;

    function setUp() public {
        // Notify deployment script that this is a test
        isTest = true;

        // Create fork
        uint256 _blockNumber = 25_043_786; // cache state for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        // Deploy the StrategyFactory
        run();

        // Deploy a Strategy wrapping the on-chain Lender
        strategy =
            IStrategy(strategyFactory.deploy(LENDER.asset(), address(LENDER), management, keeper, performanceFeeRecipient, "Flex Lender Strategy"));
        asset = ERC20(strategy.asset());
        ASSET_PRECISION = 10 ** asset.decimals();

        vm.label(address(LENDER), "Lender");
        vm.label(address(strategy), "Strategy");
        vm.label(address(asset), "Asset");

        // Accept management and set allowed
        vm.startPrank(management);
        strategy.acceptManagement();
        strategy.setAllowed(user, true);
        vm.stopPrank();

        // Make sure the Lender's deposit limit doesn't constrain the fuzz range
        vm.prank(LENDER.management());
        LENDER.setDepositLimit(type(uint256).max);

        // Adjust fuzzing limits based on asset decimals
        if (asset.decimals() < 18) {
            uint256 _decimalsDiff = 18 - asset.decimals();
            maxFuzzAmount = maxFuzzAmount / (10 ** _decimalsDiff);
            minFuzzAmount = minFuzzAmount / (10 ** _decimalsDiff);
        }
    }

    function test_setupStrategyOK() public {
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
    }

    function test_operation(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 1 days);

        // Report profit
        vm.prank(strategy.keeper());
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS / 10));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 1 days);

        // Simulate yield by airdropping the asset directly to the strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(strategy.keeper());
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());
        // 1023 230330
        // 1026 090120

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS / 10));

        // Set perf fee to 10%
        vm.prank(management);
        strategy.setPerformanceFee(1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 10 days);

        // Report profit
        vm.prank(strategy.keeper());
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        vm.prank(performanceFeeRecipient);
        strategy.redeem(expectedShares, performanceFeeRecipient, performanceFeeRecipient);

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(asset.balanceOf(performanceFeeRecipient), expectedShares, "!perf fee out");
    }

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 1 days);

        // Report profit
        vm.prank(strategy.keeper());
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        assertGe(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 1 days);

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(management);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_forceFreeFunds_idleOnly(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        IDutchDesk _dutchDesk = IDutchDesk(ITroveManager(address(LENDER.TROVE_MANAGER())).dutch_desk());
        uint256 _nonceBefore = _dutchDesk.nonce();

        vm.prank(management);
        uint256 _freed = strategy.forceFreeFunds(_amount);

        // No auction was kicked - the Lender covered it from idle
        assertEq(_dutchDesk.nonce(), _nonceBefore, "auction kicked");

        // Strategy got the asset atomically and burned Lender shares
        assertApproxEqAbs(_freed, _amount, 1, "E0");
        assertEq(asset.balanceOf(address(strategy)), _freed, "E1");
        assertEq(LENDER.balanceOf(address(strategy)), 0, "E2");
    }

    function test_forceFreeFunds_kicksAuction(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drain the Lender's idle by borrowing roughly all of it
        openTrove(address(77), _amount);
        assertLt(asset.balanceOf(address(LENDER)), _amount, "lender still has idle");

        IDutchDesk _dutchDesk = IDutchDesk(ITroveManager(address(LENDER.TROVE_MANAGER())).dutch_desk());
        IAuction _auction = IAuction(_dutchDesk.auction());
        uint256 _nonceBefore = _dutchDesk.nonce();

        // Force-free the full amount - shortfall kicks an auction
        vm.prank(management);
        strategy.forceFreeFunds(_amount);

        assertEq(_dutchDesk.nonce(), _nonceBefore + 1, "E0");

        uint256 _auctionId = _nonceBefore;
        assertTrue(_auction.is_active(_auctionId), "E1");
        assertGt(_auction.get_available_amount(_auctionId), 0, "E2");

        // Liquidator takes the auction at the market price; proceeds go to the strategy (auction receiver)
        takeAuction(_auctionId, _auction);

        assertEq(_auction.get_available_amount(_auctionId), 0, "E3");
        assertFalse(_auction.is_active(_auctionId), "E4");
        assertApproxEqAbs(asset.balanceOf(address(strategy)), _amount, 10, "E5");
    }

    function test_deployIdleFunds(
        uint256 _idle
    ) public {
        _idle = bound(_idle, minFuzzAmount, maxFuzzAmount);

        airdrop(asset, address(strategy), _idle);

        uint256 _expectedLenderShares = LENDER.convertToShares(_idle);

        vm.prank(management);
        uint256 _deployed = strategy.deployIdleFunds(_idle);

        assertEq(_deployed, _idle, "E0");
        assertEq(asset.balanceOf(address(strategy)), 0, "E1");
        assertEq(LENDER.balanceOf(address(strategy)), _expectedLenderShares, "E2");
    }

    function test_deployIdleFunds_capsByIdleBalance(
        uint256 _idle,
        uint256 _request
    ) public {
        _idle = bound(_idle, minFuzzAmount, maxFuzzAmount);
        _request = bound(_request, _idle + 1, type(uint256).max);

        airdrop(asset, address(strategy), _idle);

        vm.prank(management);
        uint256 _deployed = strategy.deployIdleFunds(_request);

        assertEq(_deployed, _idle, "E0");
        assertEq(asset.balanceOf(address(strategy)), 0, "E1");
    }

    function test_deployIdleFunds_capsByLenderLimit(
        uint256 _idle,
        uint256 _lenderHeadroom
    ) public {
        _idle = bound(_idle, minFuzzAmount + 1, maxFuzzAmount);
        _lenderHeadroom = bound(_lenderHeadroom, minFuzzAmount, _idle - 1);

        airdrop(asset, address(strategy), _idle);

        vm.startPrank(LENDER.management());
        LENDER.setDepositLimit(LENDER.totalAssets() + _lenderHeadroom);
        vm.stopPrank();

        uint256 _expected = LENDER.availableDepositLimit(address(strategy));
        if (_expected > _idle) _expected = _idle;

        vm.prank(management);
        uint256 _deployed = strategy.deployIdleFunds(_idle);

        assertEq(_deployed, _expected, "E0");
        assertEq(asset.balanceOf(address(strategy)), _idle - _expected, "E1");
    }

    function test_setOpen_gating(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        address _depositor = address(77);

        airdrop(asset, _depositor, _amount);

        vm.startPrank(_depositor);
        asset.approve(address(strategy), _amount);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(_amount, _depositor);
        vm.stopPrank();

        vm.prank(management);
        strategy.setOpen(true);

        vm.prank(_depositor);
        strategy.deposit(_amount, _depositor);

        assertGt(strategy.balanceOf(_depositor), 0, "E0");
    }

    function test_setAllowed_gating(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        address _depositor = address(77);
        address _stranger = address(78);

        airdrop(asset, _depositor, _amount);
        airdrop(asset, _stranger, _amount);

        vm.prank(management);
        strategy.setAllowed(_depositor, true);

        vm.startPrank(_depositor);
        asset.approve(address(strategy), _amount);
        strategy.deposit(_amount, _depositor);
        vm.stopPrank();

        vm.startPrank(_stranger);
        asset.approve(address(strategy), _amount);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(_amount, _stranger);
        vm.stopPrank();
    }

    function test_availableWithdrawLimit_capsByLenderIdle(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drain the Lender's idle by opening a trove
        openTrove(address(77), _amount);

        uint256 _lenderIdle = asset.balanceOf(address(LENDER));
        assertLt(_lenderIdle, _amount, "lender still has idle");
        assertEq(strategy.availableWithdrawLimit(user), _lenderIdle, "E0");
    }

    function test_setOpen_wrongCaller(
        address _wrongCaller,
        bool _isOpen
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        strategy.setOpen(_isOpen);
    }

    function test_setAllowed_wrongCaller(
        address _wrongCaller,
        address _address,
        bool _isAllowed
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        strategy.setAllowed(_address, _isAllowed);
    }

    function test_forceFreeFunds_wrongCaller(
        address _wrongCaller,
        uint256 _amount
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        strategy.forceFreeFunds(_amount);
    }

    function test_deployIdleFunds_wrongCaller(
        address _wrongCaller,
        uint256 _amount
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        strategy.deployIdleFunds(_amount);
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    function airdrop(
        ERC20 _asset,
        address _to,
        uint256 _amount
    ) public {
        uint256 _balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, _balanceBefore + _amount);
    }

    function depositIntoStrategy(
        IStrategy _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategy _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function openTrove(
        address _borrower,
        uint256 _borrowAmount
    ) public returns (uint256 _troveId) {
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        IPriceOracle _oracle = IPriceOracle(_tm.price_oracle());
        ERC20 _collateralToken = ERC20(_tm.collateral_token());

        // Aim for a 10% buffer above MCR
        uint256 _targetCR = _tm.minimum_collateral_ratio() * 110 / 100;
        uint256 _collateralNeeded = (_borrowAmount * _targetCR / ASSET_PRECISION) * 1e36 / _oracle.get_price();

        // Modest interest rate above min
        uint256 _rate = _tm.min_annual_interest_rate() * 20;

        airdrop(_collateralToken, _borrower, _collateralNeeded);

        vm.startPrank(_borrower);
        _collateralToken.approve(address(_tm), _collateralNeeded);
        _troveId = _tm.open_trove(
            block.timestamp, // owner_index
            _collateralNeeded,
            _borrowAmount,
            0, // upper_hint
            0, // lower_hint
            _rate,
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
        vm.stopPrank();
    }

    function openAndCloseTrove(
        uint256 _borrowAmount,
        uint256 _holdDuration
    ) public {
        address _borrower = address(77);

        // Open the trove (interest starts accruing on the borrowed amount)
        uint256 _troveId = openTrove(_borrower, _borrowAmount);

        // Hold the trove open so interest accrues
        skip(_holdDuration);

        // Cover any accrued interest before repaying
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        uint256 _debt = _tm.get_trove_debt_after_interest(_troveId);
        uint256 _balance = asset.balanceOf(_borrower);
        if (_debt > _balance) airdrop(asset, _borrower, _debt - _balance);

        // Repay the trove and return the collateral; the upfront fee plus accrued interest stay with the Lender
        vm.startPrank(_borrower);
        asset.approve(address(_tm), _debt);
        _tm.close_trove(_troveId);
        vm.stopPrank();

        // Report the Lender
        vm.prank(LENDER.keeper());
        LENDER.report();

        // Skip profit unlock time
        skip(LENDER.profitMaxUnlockTime());
    }

    function takeAuction(
        uint256 _auctionId,
        IAuction _auction
    ) public {
        address _liquidator = address(88);

        // Skip time until the auction price reaches the oracle price
        uint256 _stepDuration = _auction.step_duration();
        IPriceOracle _oracle = IPriceOracle(ITroveManager(address(LENDER.TROVE_MANAGER())).price_oracle());
        uint256 _targetPrice = _oracle.get_price(false);
        uint256 _currentPrice = _auction.get_price(_auctionId, block.timestamp);
        uint256 _steps = 0;

        while (_currentPrice > _targetPrice && _steps < 1440) {
            _steps++;
            _currentPrice = _auction.get_price(_auctionId, block.timestamp + _steps * _stepDuration);
        }

        if (_steps > 0) skip(_steps * _stepDuration);

        uint256 _amountNeeded = _auction.get_needed_amount(_auctionId, type(uint256).max, block.timestamp);
        airdrop(asset, _liquidator, _amountNeeded);

        vm.startPrank(_liquidator);
        asset.approve(address(_auction), _amountNeeded);
        _auction.take(_auctionId, type(uint256).max, _liquidator, "");
        vm.stopPrank();
    }

    function checkStrategyTotals(
        IStrategy _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

}
