// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";

import {ILender} from "../lender/interfaces/ILender.sol";

/// @title Flex Lender Strategy
/// @author Flex
/// @notice Tokenized Strategy vault that is used by an allocator vault to provide liquidity to a market
contract FlexLenderStrategy is BaseHealthCheck {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Events
    // ============================================================================================

    /// @notice Emitted when management calls `forceFreeFunds`
    /// @param amount The amount of asset actually freed
    event ForceFreeFunds(uint256 amount);

    /// @notice Emitted when management calls `deployIdleFunds`
    /// @param amount The amount of asset actually deployed
    event DeployIdleFunds(uint256 amount);

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Lender contract
    ILender public immutable LENDER;

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @notice Whether deposits are open to everyone
    bool public openDeposits;

    /// @notice Addresses allowed to deposit when openDeposits is false
    mapping(address => bool) public allowed;

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Constructor
    /// @param _asset The address of the borrow token
    /// @param _lender The address of the Lender contract
    /// @param _name The name of the strategy
    constructor(
        address _asset,
        address _lender,
        string memory _name
    ) BaseHealthCheck(_asset, _name) {
        // Set Lender contract
        LENDER = ILender(_lender);
        require(LENDER.asset() == _asset, "!asset");

        // Max approve the Lender to pull the asset
        asset.forceApprove(_lender, type(uint256).max);
    }

    // ============================================================================================
    // Public view functions
    // ============================================================================================

    /// @inheritdoc BaseStrategy
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        return openDeposits || allowed[_owner] ? LENDER.availableDepositLimit(address(this)) : 0;
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return asset.balanceOf(address(this)) + asset.balanceOf(address(LENDER));
    }

    // ============================================================================================
    // Management functions
    // ============================================================================================

    /// @notice Force a withdrawal from the Lender
    /// @dev Only callable by management
    /// @dev Could trigger a collateral redemption, meaning assets will arrive asynchronously
    ///      and may create a loss on the collateral/asset conversion
    /// @param _amount The amount of asset to free
    /// @param _minOut Minimum amount of asset delivered atomically
    /// @return The actual amount of asset freed
    function forceFreeFunds(
        uint256 _amount,
        uint256 _minOut
    ) external onlyManagement returns (uint256) {
        // Cap the amount to our max redeem
        uint256 _shares = Math.min(LENDER.previewWithdraw(_amount), LENDER.maxRedeem(address(this)));

        // Withdraw and potentially trigger a collateral redemption
        if (_shares > 0) _amount = LENDER.redeem(_shares, address(this), address(this));

        // Make sure we got at least the minimum amount requested
        require(_amount >= _minOut, "shrekt");

        // Emit event
        emit ForceFreeFunds(_amount);

        // Return the actual amount freed
        return _amount;
    }

    /// @notice Deploy any idle funds to the Lender
    /// @dev Only callable by management
    /// @param _amount The amount of asset to deploy
    /// @return The actual amount of asset deployed
    function deployIdleFunds(
        uint256 _amount
    ) external onlyManagement returns (uint256) {
        // Cap the amount by our idle balance
        _amount = Math.min(asset.balanceOf(address(this)), _amount);

        // Cap by our max deposit
        _amount = Math.min(_amount, LENDER.maxDeposit(address(this)));

        // Deposit
        if (_amount > 0) LENDER.deposit(_amount, address(this));

        // Emit event
        emit DeployIdleFunds(_amount);

        // Return the actual amount deployed
        return _amount;
    }

    /// @notice Open or close strategy deposits globally
    /// @dev If closed, only `allowed[_owner]` addresses can deposit
    /// @param _isOpen Whether deposits are open to everyone
    function setOpen(
        bool _isOpen
    ) external onlyManagement {
        openDeposits = _isOpen;
    }

    /// @notice Allow or disallow a specific address to deposit
    /// @param _address Address to allow or disallow
    /// @param _isAllowed Whether the address is allowed to deposit
    function setAllowed(
        address _address,
        bool _isAllowed
    ) external onlyManagement {
        allowed[_address] = _isAllowed;
    }

    // ============================================================================================
    // Internal mutative functions
    // ============================================================================================

    /// @inheritdoc BaseStrategy
    function _deployFunds(
        uint256 _amount
    ) internal override {
        LENDER.deposit(_amount, address(this));
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(
        uint256 _amount
    ) internal override {
        // Withdraw without triggering a collateral redemption
        LENDER.redeem(LENDER.convertToShares(_amount), address(this), address(this));
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal view override returns (uint256) {
        // Total assets is whatever idle asset we have + our Lender shares converted to asset
        return asset.balanceOf(address(this)) + LENDER.convertToAssets(LENDER.balanceOf(address(this)));
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(
        uint256 _amount
    ) internal override {
        // Cap the amount to our max redeem
        uint256 _shares = Math.min(LENDER.previewWithdraw(_amount), LENDER.maxRedeem(address(this)));

        // Withdraw everything we can, trigger a collateral redemption if needed
        LENDER.redeem(_shares, address(this), address(this));
    }

}
