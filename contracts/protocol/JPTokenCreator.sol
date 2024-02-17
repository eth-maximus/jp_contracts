/*
    SPDX-License-Identifier: Apache License, Version 2.0
*/

pragma solidity 0.6.10;
pragma experimental "ABIEncoderV2";

import { IController } from "../interfaces/IController.sol";
import { JPToken } from "./JPToken.sol";
import { AddressArrayUtils } from "../lib/AddressArrayUtils.sol";

contract JPTokenCreator {
    using AddressArrayUtils for address[];

    /* ============ Events ============ */

    event JPTokenCreated(address indexed _jpToken, address _manager, string _name, string _symbol);

    /* ============ State Variables ============ */

    // Instance of the controller smart contract
    IController public controller;

    /* ============ Functions ============ */

    /**
     * @param _controller          Instance of the controller
     */
    constructor(IController _controller) public {
        controller = _controller;
    }

    /**
     * Creates a JPToken smart contract and registers the JPToken with the controller. The JPTokens are composed
     * of positions that are instantiated as DEFAULT (positionState = 0) state.
     *
     * @param _components             List of addresses of components for initial Positions
     * @param _units                  List of units. Each unit is the # of components per 10^18 of a JPToken
     * @param _modules                List of modules to enable. All modules must be approved by the Controller
     * @param _manager                Address of the manager
     * @param _name                   Name of the JPToken
     * @param _symbol                 Symbol of the JPToken
     * @return address                Address of the newly created JPToken
     */
    function create(
        address[] memory _components,
        int256[] memory _units,
        address[] memory _modules,
        address _manager,
        string memory _name,
        string memory _symbol
    )
        external
        returns (address)
    {
        require(_components.length > 0, "Must have at least 1 component");
        require(_components.length == _units.length, "Component and unit lengths must be the same");
        require(!_components.hasDuplicate(), "Components must not have a duplicate");
        require(_modules.length > 0, "Must have at least 1 module");
        require(_manager != address(0), "Manager must not be empty");

        for (uint256 i = 0; i < _components.length; i++) {
            require(_components[i] != address(0), "Component must not be null address");
            require(_units[i] > 0, "Units must be greater than 0");
        }

        for (uint256 j = 0; j < _modules.length; j++) {
            require(controller.isModule(_modules[j]), "Must be enabled module");
        }

        // Creates a new JPToken instance
        JPToken jpToken = new JPToken(
            _components,
            _units,
            _modules,
            controller,
            _manager,
            _name,
            _symbol
        );

        // Registers JP with controller
        controller.addJP(address(jpToken));

        emit JPTokenCreated(address(jpToken), _manager, _name, _symbol);

        return address(jpToken);
    }
}

