// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ILeverageZapper} from "./interfaces/ILeverageZapper.sol";

import {IPriceOracle} from "../test/interfaces/IPriceOracle.sol";
import {ITroveManager} from "../test/interfaces/ITroveManager.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// open a leveraged trove via Enso:
// forge script script/OpenLeveragedTrove.s.sol:OpenLeveragedTrove --slow --rpc-url $RPC_URL --ffi --broadcast

contract OpenLeveragedTrove is Script {

    // ============================================================================================
    // Parameters - tweak before running
    // ============================================================================================

    // Market
    ITroveManager public constant TROVE_MANAGER = ITroveManager(0xd82DB9893751E9C90E2a6C3bE31183048E8E2e49);

    // Periphery (prod from script/README.md)
    ILeverageZapper public constant LEVERAGE_ZAPPER = ILeverageZapper(0xbF3E996821D43ac3b6069Ae74Efa101ffc6137E0);

    // Position
    uint256 public constant TARGET_LEVERAGE = 10; // e.g. 10x
    uint256 public constant USER_COLLATERAL = 1_000e6; // raw amount in collateral decimals
    uint256 public constant ANNUAL_INTEREST_RATE = 1e3; // 0.1% on USDC (= `min_annual_interest_rate` = `one_pct / 10`)

    // Slippage tolerance on the flash-loan-side collateral swap (bps of the buffered debt)
    uint256 public constant SLIPPAGE_BPS = 1; // 0.01%
    uint256 public constant BPS = 10_000;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;

    // ============================================================================================
    // Storage (hoisted out of `run()` to relieve stack pressure)
    // ============================================================================================

    address internal _user;
    address internal _collateralToken;
    address internal _borrowToken;
    uint256 internal _price;
    uint256 internal _collDec;
    uint256 internal _borrowDec;
    string internal _collSym;
    string internal _borrowSym;
    uint256 internal _additionalCollateral;
    uint256 internal _totalCollateral;
    uint256 internal _baseDebt;
    uint256 internal _flashLoanAmount;
    uint256 internal _debtAmount;
    uint256 internal _maxUpfrontFee;
    uint256 internal _minBorrowOut;
    uint256 internal _minCollateralOut;
    uint256 internal _borrowPerColl;
    uint256 internal _rateBps;
    address internal _swapRouter;
    bytes internal _swapData;
    uint256 internal _ownerIndex;
    uint256 internal _troveId;
    ITroveManager.Trove internal _trove;
    uint256 internal _achievedLeverageBps;
    uint256 internal _collValue;
    uint256 internal _ltvBps;
    uint256 internal _mcrPct;
    uint256 internal _maxLtvBps;

    // ============================================================================================
    // Run
    // ============================================================================================

    function run() public {
        uint256 _pk = vm.envUint("BORROWER_PRIVATE_KEY");
        _user = vm.addr(_pk);
        console.log("User:       %s", _user);

        require(TARGET_LEVERAGE >= 2, "leverage must be >= 2");

        // Read market state
        _collateralToken = TROVE_MANAGER.collateral_token();
        _borrowToken = TROVE_MANAGER.borrow_token();
        _price = IPriceOracle(TROVE_MANAGER.price_oracle()).get_price();

        _collDec = IERC20Metadata(_collateralToken).decimals();
        _borrowDec = IERC20Metadata(_borrowToken).decimals();
        _collSym = IERC20Metadata(_collateralToken).symbol();
        _borrowSym = IERC20Metadata(_borrowToken).symbol();

        // Compute amounts
        _additionalCollateral = USER_COLLATERAL * (TARGET_LEVERAGE - 1);
        _totalCollateral = USER_COLLATERAL * TARGET_LEVERAGE;
        _baseDebt = _additionalCollateral * _price / ORACLE_PRICE_SCALE;
        _flashLoanAmount = _baseDebt;
        // Buffer the debt to cover swap slippage (lever zapper sweeps excess back to user)
        _debtAmount = _baseDebt * BPS / (BPS - SLIPPAGE_BPS);

        // Slippage / sandwich-protection floors and ceilings
        // - max upfront fee: quote + a small tolerance for avg-rate movement
        // - min borrow out: require full atomic delivery so the flash loan is always repayable
        // - min collateral out: not reached if min_borrow_out forces the no-redemption path
        _maxUpfrontFee = TROVE_MANAGER.get_upfront_fee(_debtAmount, ANNUAL_INTEREST_RATE) * (BPS + SLIPPAGE_BPS) / BPS;
        _minBorrowOut = _debtAmount;
        _minCollateralOut = 0;

        // Sanity checks before any state changes
        require(_debtAmount > TROVE_MANAGER.min_debt(), "!min_debt");
        require(IERC20(_collateralToken).balanceOf(_user) >= USER_COLLATERAL, "!USER_COLLATERAL");

        // Borrow value of 1 unit of collateral (i.e. price expressed in borrow_token decimals)
        _borrowPerColl = (10 ** _collDec) * _price / ORACLE_PRICE_SCALE;
        // Annual interest rate in bps for display
        _rateBps = ANNUAL_INTEREST_RATE * 100 / TROVE_MANAGER.one_pct();

        // Print plan
        console.log("---------------------------------");
        console.log("Trove Manager:        %s", address(TROVE_MANAGER));
        console.log("Collateral token:     %s (%s)", _collSym, _collateralToken);
        console.log("Borrow token:         %s (%s)", _borrowSym, _borrowToken);
        console.log("Price:                1 %s = %s", _collSym, _format(_borrowPerColl, _borrowDec, _borrowSym));
        console.log("Target leverage:      %sx", TARGET_LEVERAGE);
        console.log("User collateral:      %s", _format(USER_COLLATERAL, _collDec, _collSym));
        console.log("Additional coll:      %s", _format(_additionalCollateral, _collDec, _collSym));
        console.log("Total trove coll:     %s", _format(_totalCollateral, _collDec, _collSym));
        console.log("Base debt:            %s", _format(_baseDebt, _borrowDec, _borrowSym));
        console.log("Buffered debt:        %s", _format(_debtAmount, _borrowDec, _borrowSym));
        console.log("Flash loan amount:    %s", _format(_flashLoanAmount, _borrowDec, _borrowSym));
        console.log("Annual interest rate: %s bps", _rateBps);
        console.log("Max upfront fee:      %s", _format(_maxUpfrontFee, _borrowDec, _borrowSym));
        console.log("Min borrow out:       %s", _format(_minBorrowOut, _borrowDec, _borrowSym));
        console.log("Min collateral out:   %s", _format(_minCollateralOut, _collDec, _collSym));
        console.log("---------------------------------");

        // Get the enso swap calldata (borrow_token -> collateral_token).
        // IMPORTANT: pass the SwapExecutor as the Enso `fromAddress` so the route writes the output
        // back to the executor (which sweeps it to the LeverageZapper). If we pass the user instead,
        // Enso bakes the user's address into the deposit receiver and the zapper sees zero output.
        (_swapRouter, _swapData) = _getEnsoSwapData(block.chainid, _borrowToken, _collateralToken, _flashLoanAmount, LEVERAGE_ZAPPER.SWAP_EXECUTOR());
        console.log("Swap router:          %s", _swapRouter);
        console.log("Swap calldata bytes:  %s", _swapData.length);

        // Make sure the router is whitelisted on the zapper
        require(LEVERAGE_ZAPPER.routers(_swapRouter), "swap router not whitelisted on LeverageZapper");

        _ownerIndex = block.timestamp;

        vm.startBroadcast(_pk);

        // Approve zapper to pull the user's collateral
        IERC20(_collateralToken).approve(address(LEVERAGE_ZAPPER), USER_COLLATERAL);

        // Approve zapper as a Trove Manager operator (needed for future lever_up / lever_down / close_leveraged_trove on this trove)
        if (!TROVE_MANAGER.approved(_user, address(LEVERAGE_ZAPPER))) {
            console.log("Approving LeverageZapper as a Trove Manager operator...");
            TROVE_MANAGER.approve(address(LEVERAGE_ZAPPER), true);
        }

        // Open the leveraged trove
        _troveId = LEVERAGE_ZAPPER.open_leveraged_trove(
            ILeverageZapper.OpenLeveragedData({
                owner: _user,
                trove_manager: address(TROVE_MANAGER),
                flash_loan_token: _borrowToken,
                auction_taker: address(0),
                owner_index: _ownerIndex,
                flash_loan_amount: _flashLoanAmount,
                collateral_amount: USER_COLLATERAL,
                debt_amount: _debtAmount,
                prev_id: 0,
                next_id: 0,
                annual_interest_rate: ANNUAL_INTEREST_RATE,
                max_upfront_fee: _maxUpfrontFee,
                min_borrow_out: _minBorrowOut,
                min_collateral_out: _minCollateralOut,
                collateral_swap: ILeverageZapper.SwapData({router: _swapRouter, data: _swapData}),
                debt_swap: ILeverageZapper.SwapData({router: address(0), data: ""})
            })
        );

        vm.stopBroadcast();

        // Verify
        _trove = TROVE_MANAGER.troves(_troveId);
        require(_trove.owner == _user, "trove owner mismatch");
        require(uint256(_trove.status) == uint256(ITroveManager.Status.active), "trove not active");
        require(_trove.collateral > 0, "trove has no collateral");
        require(_trove.debt > 0, "trove has no debt");

        // Achieved leverage = trove.collateral / user_collateral
        _achievedLeverageBps = _trove.collateral * BPS / USER_COLLATERAL;

        // LTV = debt / collateral_value_in_borrow (bps).
        // Max LTV = 1 / MCR_real = BPS * 100 / MCR_pct.
        _collValue = _trove.collateral * _price / ORACLE_PRICE_SCALE;
        _ltvBps = _trove.debt * BPS / _collValue;
        _mcrPct = TROVE_MANAGER.minimum_collateral_ratio() / TROVE_MANAGER.one_pct();
        _maxLtvBps = BPS * 100 / _mcrPct;

        console.log("---------------------------------");
        console.log("Trove ID:             %s", _troveId);
        console.log("Trove collateral:     %s", _format(_trove.collateral, _collDec, _collSym));
        console.log("Trove debt:           %s", _format(_trove.debt, _borrowDec, _borrowSym));
        console.log("Achieved leverage:    %s.%s%sx", _achievedLeverageBps / BPS, (_achievedLeverageBps / 100) % 100, _achievedLeverageBps % 100);
        console.log("LTV:                  %s (max %s)", _fmtPct(_ltvBps), _fmtPct(_maxLtvBps));
        console.log("---------------------------------");
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev Format a bps value as `"XX.YY%"`.
    function _fmtPct(
        uint256 _bps
    ) internal pure returns (string memory) {
        uint256 _whole = _bps / 100;
        uint256 _frac = _bps % 100;
        string memory _fracStr = vm.toString(_frac);
        if (bytes(_fracStr).length < 2) _fracStr = string.concat("0", _fracStr);
        return string.concat(vm.toString(_whole), ".", _fracStr, "%");
    }

    /// @dev Format a raw token amount as `"X.YYYYYY SYM"` using the token's decimals.
    function _format(
        uint256 _amount,
        uint256 _decimals,
        string memory _symbol
    ) internal pure returns (string memory) {
        uint256 _scale = 10 ** _decimals;
        uint256 _whole = _amount / _scale;
        uint256 _frac = _amount % _scale;

        // Pad the fractional part with leading zeros to `_decimals` digits
        string memory _fracStr = vm.toString(_frac);
        while (bytes(_fracStr).length < _decimals) _fracStr = string.concat("0", _fracStr);

        return string.concat(vm.toString(_whole), ".", _fracStr, " ", _symbol);
    }

    /// @dev Calls `script/get_enso_swap.sh` which outputs `abi.encodePacked(router, data)`.
    function _getEnsoSwapData(
        uint256 _chainId,
        address _inputToken,
        address _outputToken,
        uint256 _amount,
        address _sender
    ) internal returns (address _router, bytes memory _data) {
        string[] memory _cmd = new string[](7);
        _cmd[0] = "bash";
        _cmd[1] = "script/get_enso_swap.sh";
        _cmd[2] = vm.toString(_chainId);
        _cmd[3] = vm.toString(_inputToken);
        _cmd[4] = vm.toString(_outputToken);
        _cmd[5] = vm.toString(_amount);
        _cmd[6] = vm.toString(_sender);
        bytes memory _raw = vm.ffi(_cmd);

        require(_raw.length > 20, "enso: empty response");

        // First 20 bytes = router, rest = calldata
        assembly {
            _router := shr(96, mload(add(_raw, 32)))
            let dataLen := sub(mload(_raw), 20)
            _data := mload(0x40)
            mstore(_data, dataLen)
            mstore(0x40, add(add(_data, 32), dataLen))
        }
        for (uint256 i = 0; i < _data.length; i++) {
            _data[i] = _raw[i + 20];
        }
    }

}
