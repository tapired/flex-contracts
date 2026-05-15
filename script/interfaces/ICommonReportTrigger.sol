// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ICommonReportTrigger {

    function setCustomStrategyTrigger(
        address _strategy,
        address _trigger
    ) external;

}
