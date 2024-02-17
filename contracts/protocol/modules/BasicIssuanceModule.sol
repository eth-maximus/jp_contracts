/*
    Copyright 2021 Cook Finance.
    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
    SPDX-License-Identifier: Apache License, Version 2.0
*/

pragma solidity 0.6.10;
pragma experimental "ABIEncoderV2";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";

import { IController } from "../../interfaces/IController.sol";
import { IManagerIssuanceHook } from "../../interfaces/IManagerIssuanceHook.sol";
import { Invoke } from "../lib/Invoke.sol";
import { IJPToken } from "../../interfaces/IJPToken.sol";
import { ModuleBase } from "../lib/ModuleBase.sol";
import { Position } from "../lib/Position.sol";
import { PreciseUnitMath } from "../../lib/PreciseUnitMath.sol";

/**
 * @title BasicIssuanceModule
 * @author Cook Finance
 *
 * Module that enables issuance and redemption functionality on a JPToken. This is a module that is
 * required to bring the totalSupply of a JP above 0.
 */
contract BasicIssuanceModule is ModuleBase, ReentrancyGuard {
    using Invoke for IJPToken;
    using Position for IJPToken.Position;
    using Position for IJPToken;
    using PreciseUnitMath for uint256;
    using SafeMath for uint256;
    using SafeCast for int256;

    /* ============ Events ============ */

    event JPTokenIssued(
        address indexed _JPToken,
        address indexed _issuer,
        address indexed _to,
        address _hookContract,
        uint256 _quantity
    );
    event JPTokenRedeemed(
        address indexed _JPToken,
        address indexed _redeemer,
        address indexed _to,
        uint256 _quantity
    );

    /* ============ State Variables ============ */

    // Mapping of JPToken to Issuance hook configurations
    mapping(IJPToken => IManagerIssuanceHook) public managerIssuanceHook;

    /* ============ Constructor ============ */

    /**
     * Set state controller state variable
     *
     * @param _controller             Address of controller contract
     */
    constructor(IController _controller) public ModuleBase(_controller) {}

    /* ============ External Functions ============ */

    /**
     * Deposits the JPToken's position components into the JPToken and mints the JPToken of the given quantity
     * to the specified _to address. This function only handles Default Positions (positionState = 0).
     *
     * @param _JPToken             Instance of the JPToken contract
     * @param _quantity             Quantity of the JPToken to mint
     * @param _to                   Address to mint JPToken to
     */
    function issue(
        IJPToken _JPToken,
        uint256 _quantity,
        address _to
    ) 
        external
        nonReentrant
        onlyValidAndInitializedJP(_JPToken)
    {
        require(_quantity > 0, "Issue quantity must be > 0");

        address hookContract = _callPreIssueHooks(_JPToken, _quantity, msg.sender, _to);

        (
            address[] memory components,
            uint256[] memory componentQuantities
        ) = getRequiredComponentUnitsForIssue(_JPToken, _quantity);

        // For each position, transfer the required underlying to the JPToken
        for (uint256 i = 0; i < components.length; i++) {
            // Transfer the component to the JPToken
            transferFrom(
                IERC20(components[i]),
                msg.sender,
                address(_JPToken),
                componentQuantities[i]
            );
        }

        // Mint the JPToken
        _JPToken.mint(_to, _quantity);

        emit JPTokenIssued(address(_JPToken), msg.sender, _to, hookContract, _quantity);
    }

    /**
     * Redeems the JPToken's positions and sends the components of the given
     * quantity to the caller. This function only handles Default Positions (positionState = 0).
     *
     * @param _JPToken             Instance of the JPToken contract
     * @param _quantity             Quantity of the JPToken to redeem
     * @param _to                   Address to send component assets to
     */
    function redeem(
        IJPToken _JPToken,
        uint256 _quantity,
        address _to
    )
        external
        nonReentrant
        onlyValidAndInitializedJP(_JPToken)
    {
        require(_quantity > 0, "Redeem quantity must be > 0");

        // Burn the JPToken - ERC20's internal burn already cheJPs that the user has enough balance
        _JPToken.burn(msg.sender, _quantity);

        // For each position, invoke the JPToken to transfer the tokens to the user
        address[] memory components = _JPToken.getComponents();
        for (uint256 i = 0; i < components.length; i++) {
            address component = components[i];
            require(!_JPToken.hasExternalPosition(component), "Only default positions are supported");

            uint256 unit = _JPToken.getDefaultPositionRealUnit(component).toUint256();

            // Use preciseMul to round down to ensure overcollateration when small redeem quantities are provided
            uint256 componentQuantity = _quantity.preciseMul(unit);

            // Instruct the JPToken to transfer the component to the user
            _JPToken.strictInvokeTransfer(
                component,
                _to,
                componentQuantity
            );
        }

        emit JPTokenRedeemed(address(_JPToken), msg.sender, _to, _quantity);
    }

    /**
     * Initializes this module to the JPToken with issuance-related hooks. Only callable by the JPToken's manager.
     * Hook addresses are optional. Address(0) means that no hook will be called
     *
     * @param _JPToken             Instance of the JPToken to issue
     * @param _preIssueHook         Instance of the Manager Contract with the Pre-Issuance Hook function
     */
    function initialize(
        IJPToken _JPToken,
        IManagerIssuanceHook _preIssueHook
    )
        external
        onlyJPManager(_JPToken, msg.sender)
        onlyValidAndPendingJP(_JPToken)
    {
        managerIssuanceHook[_JPToken] = _preIssueHook;

        _JPToken.initializeModule();
    }

    /**
     * Reverts as this module should not be removable after added. Users should always
     * have a way to redeem their JPs
     */
    function removeModule() external override {
        revert("The BasicIssuanceModule module cannot be removed");
    }

    /* ============ External Getter Functions ============ */

    /**
     * Retrieves the addresses and units required to mint a particular quantity of JPToken.
     *
     * @param _JPToken             Instance of the JPToken to issue
     * @param _quantity             Quantity of JPToken to issue
     * @return address[]            List of component addresses
     * @return uint256[]            List of component units required to issue the quantity of JPTokens
     */
    function getRequiredComponentUnitsForIssue(
        IJPToken _JPToken,
        uint256 _quantity
    )
        public
        view
        onlyValidAndInitializedJP(_JPToken)
        returns (address[] memory, uint256[] memory)
    {
        address[] memory components = _JPToken.getComponents();

        uint256[] memory notionalUnits = new uint256[](components.length);

        for (uint256 i = 0; i < components.length; i++) {
            require(!_JPToken.hasExternalPosition(components[i]), "Only default positions are supported");

            notionalUnits[i] = _JPToken.getDefaultPositionRealUnit(components[i]).toUint256().preciseMulCeil(_quantity);
        }

        return (components, notionalUnits);
    }

    /* ============ Internal Functions ============ */

    /**
     * If a pre-issue hook has been configured, call the external-protocol contract. Pre-issue hook logic
     * can contain arbitrary logic including validations, external function calls, etc.
     */
    function _callPreIssueHooks(
        IJPToken _JPToken,
        uint256 _quantity,
        address _caller,
        address _to
    )
        internal
        returns(address)
    {
        IManagerIssuanceHook preIssueHook = managerIssuanceHook[_JPToken];
        if (address(preIssueHook) != address(0)) {
            preIssueHook.invokePreIssueHook(_JPToken, _quantity, _caller, _to);
            return address(preIssueHook);
        }

        return address(0);
    }
}