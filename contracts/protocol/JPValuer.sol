/*
    SPDX-License-Identifier: Apache License, Version 2.0
*/

pragma solidity 0.6.10;
pragma experimental "ABIEncoderV2";

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";

import { IController } from "../interfaces/IController.sol";
import { IJPToken } from "../interfaces/IJPToken.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { PreciseUnitMath } from "../lib/PreciseUnitMath.sol";
import { Position } from "./lib/Position.sol";
import { ResourceIdentifier } from "./lib/ResourceIdentifier.sol";


contract JeepValuer {
    using PreciseUnitMath for int256;
    using PreciseUnitMath for uint256;
    using Position for IJPToken;
    using ResourceIdentifier for IController;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SignedSafeMath for int256;
    
    /* ============ State Variables ============ */

    // Instance of the Controller contract
    IController public controller;

    /* ============ Constructor ============ */

    /**
     * Set state variables and map asset pairs to their oracles
     *
     * @param _controller             Address of controller contract
     */
    constructor(IController _controller) public {
        controller = _controller;
    }

    /* ============ External Functions ============ */

    /**
     * Gets the valuation of a JPToken using data from the price oracle. Reverts
     * if no price exists for a component in the JPToken. Note: this works for external
     * positions and negative (debt) positions.
     * 
     * Note: There is a risk that the valuation is off if airdrops aren't retrieved or
     * debt builds up via interest and its not reflected in the position
     *
     * @param _jpToken        JPToken instance to get valuation
     * @param _quoteAsset      Address of token to quote valuation in
     *
     * @return                 JPToken valuation in terms of quote asset in precise units 1e18
     */
    function calculateJPTokenValuation(IJPToken _jpToken, address _quoteAsset) external view returns (uint256) {
        IPriceOracle priceOracle = controller.getPriceOracle();
        address masterQuoteAsset = priceOracle.masterQuoteAsset();
        address[] memory components = _jpToken.getComponents();
        int256 valuation;

        for (uint256 i = 0; i < components.length; i++) {
            address component = components[i];
            // Get component price from price oracle. If price does not exist, revert.
            uint256 componentPrice = priceOracle.getPrice(component, masterQuoteAsset);

            int256 aggregateUnits = _jpToken.getTotalComponentRealUnits(component);

            // Normalize each position unit to preciseUnits 1e18 and cast to signed int
            uint256 unitDecimals = ERC20(component).decimals();
            uint256 baseUnits = 10 ** unitDecimals;
            int256 normalizedUnits = aggregateUnits.preciseDiv(baseUnits.toInt256());

            // Calculate valuation of the component. Debt positions are effectively subtracted
            valuation = normalizedUnits.preciseMul(componentPrice.toInt256()).add(valuation);
        }

        if (masterQuoteAsset != _quoteAsset) {
            uint256 quoteToMaster = priceOracle.getPrice(_quoteAsset, masterQuoteAsset);
            valuation = valuation.preciseDiv(quoteToMaster.toInt256());
        }

        return valuation.toUint256();
    }
}
