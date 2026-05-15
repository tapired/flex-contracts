// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ICentralAPROracle {

    function setOracle(
        address _strategy,
        address _oracle
    ) external;

}
