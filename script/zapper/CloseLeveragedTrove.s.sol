// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILeverageZapper} from "../interfaces/ILeverageZapper.sol";

import {ITroveManager} from "../../test/interfaces/ITroveManager.sol";

import {BaseZapperScript} from "./BaseZapperScript.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// close a leveraged trove via Enso:
// forge script script/zapper/CloseLeveragedTrove.s.sol:CloseLeveragedTrove --slow --rpc-url $RPC_URL --ffi --broadcast

contract CloseLeveragedTrove is BaseZapperScript {

    // ============================================================================================
    // Parameters - tweak before running
    // ============================================================================================

    // Position - set the trove id to close
    uint256 public constant TROVE_ID = 55747671586403220826287365044824856006422462050911439375647723028660622133195;

    // ============================================================================================
    // Storage (hoisted out of `run()` to relieve stack pressure)
    // ============================================================================================

    uint256 internal _debtAfterInterest;
    uint256 internal _flashLoanAmount;
    uint256 internal _collValue;
    uint256 internal _minSwapOut;
    uint256 internal _expectedUserGain;
    uint256 internal _userBorrowBefore;

    // ============================================================================================
    // Run
    // ============================================================================================

    function run() public {
        uint256 _pk = _loadUser();

        require(TROVE_ID != 0, "TROVE_ID not set");

        // Read trove state
        _trove = TROVE_MANAGER.troves(TROVE_ID);
        require(_trove.owner == _user, "trove owner mismatch");
        require(uint256(_trove.status) == uint256(ITroveManager.Status.active), "trove not active");

        _loadMarket();

        // Debt that needs to be repaid (includes accrued interest at the script's block.timestamp)
        _debtAfterInterest = TROVE_MANAGER.get_trove_debt_after_interest(TROVE_ID);

        // Flash loan a bit more than the debt so a few seconds of interest accrual between
        // script execution and broadcast doesn't leave the close short on borrow tokens
        _flashLoanAmount = _debtAfterInterest * (BPS + SLIPPAGE_BPS) / BPS;

        // Oracle value of the trove's collateral, expressed in borrow_token units
        _collValue = _trove.collateral * _price / ORACLE_PRICE_SCALE;

        // Worst-case borrow received from the collateral swap (account for swap slippage)
        _minSwapOut = _collValue * (BPS - SLIPPAGE_BPS) / BPS;

        // Sanity check the trove is solvent enough to cover the flash loan repayment
        require(_minSwapOut > _flashLoanAmount, "trove not solvent under slippage");

        // Net borrow_token the user should receive after the flash loan is repaid
        _expectedUserGain = _minSwapOut - _flashLoanAmount;

        // Get the enso swap calldata (collateral_token -> borrow_token = flash_loan_token).
        // IMPORTANT: pass the SwapExecutor as the Enso `fromAddress` so the route writes the output
        // back to the executor (which sweeps it to the LeverageZapper). If we pass the user instead,
        // Enso bakes the user's address into the receiver and the zapper sees zero output.
        (_swapRouter, _swapData) = _getEnsoSwapData(block.chainid, _collateralToken, _borrowToken, _trove.collateral, LEVERAGE_ZAPPER.SWAP_EXECUTOR());

        // Make sure the router is whitelisted on the zapper
        require(LEVERAGE_ZAPPER.routers(_swapRouter), "swap router not whitelisted on LeverageZapper");

        // Print plan
        console.log("---------------------------------");
        console.log("Trove Manager:        %s", address(TROVE_MANAGER));
        console.log("Trove ID:             %s", TROVE_ID);
        console.log("Collateral token:     %s (%s)", _collSym, _collateralToken);
        console.log("Borrow token:         %s (%s)", _borrowSym, _borrowToken);
        console.log("Price:                1 %s = %s", _collSym, _format(_borrowPerColl, _borrowDec, _borrowSym));
        console.log("Trove collateral:     %s", _format(_trove.collateral, _collDec, _collSym));
        console.log("Trove debt (now):     %s", _format(_debtAfterInterest, _borrowDec, _borrowSym));
        console.log("Collateral value:     %s", _format(_collValue, _borrowDec, _borrowSym));
        console.log("Flash loan amount:    %s", _format(_flashLoanAmount, _borrowDec, _borrowSym));
        console.log("Min swap out:         %s", _format(_minSwapOut, _borrowDec, _borrowSym));
        console.log("Expected user gain:   %s", _format(_expectedUserGain, _borrowDec, _borrowSym));
        console.log("Swap router:          %s", _swapRouter);
        console.log("Swap calldata bytes:  %s", _swapData.length);
        console.log("---------------------------------");

        _userBorrowBefore = IERC20(_borrowToken).balanceOf(_user);

        vm.startBroadcast(_pk);

        // Make sure the zapper is approved to operate on the trove (needed for close_leveraged_trove)
        _ensureZapperApproved();

        // Close the leveraged trove
        LEVERAGE_ZAPPER.close_leveraged_trove(
            ILeverageZapper.CloseLeveragedData({
                trove_manager: address(TROVE_MANAGER),
                flash_loan_token: _borrowToken,
                trove_id: TROVE_ID,
                flash_loan_amount: _flashLoanAmount,
                collateral_swap: ILeverageZapper.SwapData({router: _swapRouter, data: _swapData}),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        vm.stopBroadcast();

        // Verify the trove is closed
        _trove = TROVE_MANAGER.troves(TROVE_ID);
        require(uint256(_trove.status) == uint256(ITroveManager.Status.closed), "trove not closed");

        // Compute what the user actually received and any leftover collateral
        uint256 _userBorrowGained = IERC20(_borrowToken).balanceOf(_user) - _userBorrowBefore;
        uint256 _userCollLeftover = IERC20(_collateralToken).balanceOf(_user);
        // Convert the borrow gain into collateral units at oracle price for an apples-to-apples view
        uint256 _userBorrowGainedInColl = _userBorrowGained * ORACLE_PRICE_SCALE / _price;

        console.log("---------------------------------");
        console.log("Trove closed");
        console.log(
            "User received:        %s (= %s)",
            _format(_userBorrowGained, _borrowDec, _borrowSym),
            _format(_userBorrowGainedInColl, _collDec, _collSym)
        );
        console.log("Collateral leftover:  %s", _format(_userCollLeftover, _collDec, _collSym));
        console.log("---------------------------------");
    }

}
