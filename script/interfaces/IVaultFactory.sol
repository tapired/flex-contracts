// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IVaultFactory {

    function deploy_new_vault(
        address asset,
        string memory name,
        string memory symbol,
        address role_manager,
        uint256 profit_max_unlock_time
    ) external returns (address);

}
