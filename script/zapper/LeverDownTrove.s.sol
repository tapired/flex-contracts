// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILeverageZapper} from "../interfaces/ILeverageZapper.sol";

import {ITroveManager} from "../../test/interfaces/ITroveManager.sol";

import {BaseZapperScript} from "./BaseZapperScript.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// lever down a leveraged trove via Enso:
// forge script script/zapper/LeverDownTrove.s.sol:LeverDownTrove --slow --rpc-url $RPC_URL --ffi --broadcast

contract LeverDownTrove is BaseZapperScript {

    // ============================================================================================
    // Parameters - tweak before running
    // ============================================================================================

    // Position - set the trove id and how much collateral to pull out (paid for by repaying debt)
    uint256 public constant TROVE_ID = 55747671586403220826287365044824856006422462050911439375647723028660622133195;
    uint256 public constant COLLATERAL_TO_REMOVE = 4000e6; // raw collateral amount to remove and swap to debt token

    // ============================================================================================
    // Storage (hoisted out of `run()` to relieve stack pressure)
    // ============================================================================================

    uint256 internal _debtAfterInterest;
    uint256 internal _collValue;
    uint256 internal _flashLoanAmount;
    uint256 internal _expectedUserGain;
    uint256 internal _newCollateral;
    uint256 internal _newDebtPreview;
    uint256 internal _newLtvBps;
    uint256 internal _userBorrowBefore;

    // ============================================================================================
    // Run
    // ============================================================================================

    function run() public {
        uint256 _pk = _loadUser();

        require(TROVE_ID != 0, "TROVE_ID not set");
        require(COLLATERAL_TO_REMOVE > 0, "COLLATERAL_TO_REMOVE not set");

        // Read trove state
        _trove = TROVE_MANAGER.troves(TROVE_ID);
        require(_trove.owner == _user, "trove owner mismatch");
        require(uint256(_trove.status) == uint256(ITroveManager.Status.active), "trove not active");
        require(_trove.collateral > COLLATERAL_TO_REMOVE, "remove >= collateral (close instead)");

        _loadMarket();

        // Current debt including any accrued interest at the script's block.timestamp
        _debtAfterInterest = TROVE_MANAGER.get_trove_debt_after_interest(TROVE_ID);

        // Oracle value of the collateral we're removing, expressed in borrow_token units
        _collValue = COLLATERAL_TO_REMOVE * _price / ORACLE_PRICE_SCALE;

        // Worst-case swap output (collateral -> borrow). We size the flash loan to this number so the
        // swap proceeds are guaranteed to repay it. Anything above this is excess that the zapper
        // sweeps back to the user as borrow_token.
        _flashLoanAmount = _collValue * (BPS - SLIPPAGE_BPS) / BPS;

        // Net borrow_token the user should receive after the flash loan is repaid
        _expectedUserGain = _collValue - _flashLoanAmount;

        // Sanity checks before any state changes
        require(_flashLoanAmount > 0, "!flash_loan_amount");
        require(_flashLoanAmount < _debtAfterInterest, "flash loan exceeds debt (close instead)");

        // Preview the post-lever-down state
        _newCollateral = _trove.collateral - COLLATERAL_TO_REMOVE;
        _newDebtPreview = _debtAfterInterest - _flashLoanAmount;
        require(_newDebtPreview > TROVE_MANAGER.min_debt(), "!min_debt (close instead)");

        // LTV after the lever-down (in bps)
        _newLtvBps = _newDebtPreview * BPS * ORACLE_PRICE_SCALE / (_newCollateral * _price);
        require(_newLtvBps < _maxLtvBps, "post-lever LTV >= max");

        // Get the enso swap calldata (collateral_token -> borrow_token = flash_loan_token).
        // IMPORTANT: pass the SwapExecutor as the Enso `fromAddress` so the route writes the output
        // back to the executor (which sweeps it to the LeverageZapper). If we pass the user instead,
        // Enso bakes the user's address into the receiver and the zapper sees zero output.
        (_swapRouter, _swapData) =
            _getEnsoSwapData(block.chainid, _collateralToken, _borrowToken, COLLATERAL_TO_REMOVE, LEVERAGE_ZAPPER.SWAP_EXECUTOR());

        // Make sure the router is whitelisted on the zapper
        require(LEVERAGE_ZAPPER.routers(_swapRouter), "swap router not whitelisted on LeverageZapper");

        // Print plan
        console.log("---------------------------------");
        console.log("Trove Manager:        %s", address(TROVE_MANAGER));
        console.log("Trove ID:             %s", TROVE_ID);
        console.log("Collateral token:     %s (%s)", _collSym, _collateralToken);
        console.log("Borrow token:         %s (%s)", _borrowSym, _borrowToken);
        console.log("Price:                1 %s = %s", _collSym, _format(_borrowPerColl, _borrowDec, _borrowSym));
        console.log("--- Trove before ---");
        console.log("Collateral:           %s", _format(_trove.collateral, _collDec, _collSym));
        console.log("Debt (now):           %s", _format(_debtAfterInterest, _borrowDec, _borrowSym));
        console.log("--- Lever down ---");
        console.log("Collateral to remove: %s", _format(COLLATERAL_TO_REMOVE, _collDec, _collSym));
        console.log("Collateral value:     %s", _format(_collValue, _borrowDec, _borrowSym));
        console.log("Flash loan amount:    %s (= debt repaid)", _format(_flashLoanAmount, _borrowDec, _borrowSym));
        console.log("Expected user gain:   %s", _format(_expectedUserGain, _borrowDec, _borrowSym));
        console.log("--- Trove after (preview) ---");
        console.log("Collateral:           %s", _format(_newCollateral, _collDec, _collSym));
        console.log("Debt:                 %s", _format(_newDebtPreview, _borrowDec, _borrowSym));
        console.log("LTV:                  %s (max %s)", _fmtPct(_newLtvBps), _fmtPct(_maxLtvBps));
        console.log("---");
        console.log("Swap router:          %s", _swapRouter);
        console.log("Swap calldata bytes:  %s", _swapData.length);
        console.log("---------------------------------");

        _userBorrowBefore = IERC20(_borrowToken).balanceOf(_user);

        vm.startBroadcast(_pk);

        // Make sure the zapper is approved to operate on the trove
        _ensureZapperApproved();

        // Lever down
        LEVERAGE_ZAPPER.lever_down_trove(
            ILeverageZapper.LeverDownData({
                trove_manager: address(TROVE_MANAGER),
                flash_loan_token: _borrowToken,
                trove_id: TROVE_ID,
                flash_loan_amount: _flashLoanAmount,
                collateral_to_remove: COLLATERAL_TO_REMOVE,
                collateral_swap: ILeverageZapper.SwapData({router: _swapRouter, data: _swapData}),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        vm.stopBroadcast();

        // Verify
        _trove = TROVE_MANAGER.troves(TROVE_ID);
        require(uint256(_trove.status) == uint256(ITroveManager.Status.active), "trove not active");

        // Final LTV (using the trove's stored debt, which already reflects the repaid amount)
        uint256 _ltvBps = _trove.debt * BPS * ORACLE_PRICE_SCALE / (_trove.collateral * _price);
        uint256 _userBorrowGained = IERC20(_borrowToken).balanceOf(_user) - _userBorrowBefore;

        console.log("---------------------------------");
        console.log("Trove collateral:     %s", _format(_trove.collateral, _collDec, _collSym));
        console.log("Trove debt:           %s", _format(_trove.debt, _borrowDec, _borrowSym));
        console.log("LTV:                  %s (max %s)", _fmtPct(_ltvBps), _fmtPct(_maxLtvBps));
        console.log("User received:        %s", _format(_userBorrowGained, _borrowDec, _borrowSym));
        console.log("---------------------------------");
    }

}
