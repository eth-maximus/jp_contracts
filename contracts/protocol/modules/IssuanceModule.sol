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

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";

import { AddressArrayUtils } from "../../lib/AddressArrayUtils.sol";
import { IController } from "../../interfaces/IController.sol";
import { IManagerIssuanceHook } from "../../interfaces/IManagerIssuanceHook.sol";
import { IModuleIssuanceHook } from "../../interfaces/IModuleIssuanceHook.sol";
import { Invoke } from "../lib/Invoke.sol";
import { IJPToken } from "../../interfaces/IJPToken.sol";
import { IWETH } from "../../interfaces/external/IWETH.sol";
import { IWrapAdapter } from "../../interfaces/IWrapAdapter.sol";
import { ModuleBase } from "../lib/ModuleBase.sol";
import { Position } from "../lib/Position.sol";
import { PreciseUnitMath } from "../../lib/PreciseUnitMath.sol";
import { IExchangeAdapter } from "../../interfaces/IExchangeAdapter.sol";
import { ResourceIdentifier } from "../lib/ResourceIdentifier.sol";
import { IYieldYakStrategyV2 } from "../../interfaces/external/IYieldYakStrategyV2.sol";

/**
 * @title IssuanceModule
 * @author Cook Finance
 *
 * The IssuanceModule is a module that enables users to issue and redeem JPTokens that contain default and 
 * non-debt external Positions. Managers are able to set an external contract hook that is called before an
 * issuance is called.
 */
contract IssuanceModule is Ownable, ModuleBase, ReentrancyGuard {
    using AddressArrayUtils for address[];
    using Invoke for IJPToken;
    using Position for IJPToken;
    using Position for uint256;
    using PreciseUnitMath for uint256;
    using ResourceIdentifier for IController;
    using SafeMath for uint256;
    using SafeCast for int256;
    using SignedSafeMath for int256;

    /* ============ Struct ============ */
    struct WrapExecutionParams {
        string wrapAdapterName;     // Wrap adapter name
        address underlyingToken;    // Underlying token address of the wrapped token, ex. WETH is the underlying token of the aETH. This will be passed to wrap adapter to get wrap/unwrap call data
    }

    struct TradeInfo {
        IJPToken JPToken;                               // Instance of JPToken
        IExchangeAdapter exchangeAdapter;               // Instance of exchange adapter contract
        address sendToken;                              // Address of token being sold
        address receiveToken;                           // Address of token being bought
        uint256 totalSendQuantity;                      // Total quantity of sold token
        uint256 totalReceiveQuantity;                   // Total quantity of token to receive baJP
        uint256 preTradeSendTokenBalance;               // Total initial balance of token being sold
        uint256 preTradeReceiveTokenBalance;            // Total initial balance of token being bought
        bytes data;                                     // Arbitrary data
    }

    /* ============ Events ============ */

    event JPTokenIssued(address indexed _JPToken, address _issuer, address _to, address _hookContract, uint256 _JPMintQuantity, uint256 _issuedTokenReturned);
    event JPTokenRedeemed(address indexed _JPToken, address _redeemer, address _to, uint256 _quantity);
    event AssetExchangeExecutionParamUpdated(address indexed _component, string _newExchangeName);
    event AssetWrapExecutionParamUpdated(address indexed _component, string _newWrapAdapterName, address _newUnderlyingToken);
    event ComponentExchanged(
        IJPToken indexed _JPToken,
        address indexed _sendToken,
        address indexed _receiveToken,
        IExchangeAdapter _exchangeAdapter,
        uint256 _totalSendAmount,
        uint256 _totalReceiveAmount
    );
    event ComponentWrapped(
        IJPToken indexed _JPToken,
        address indexed _underlyingToken,
        address indexed _wrappedToken,
        uint256 _underlyingQuantity,
        uint256 _wrappedQuantity,
        string _integrationName
    );
    event ComponentUnwrapped(
        IJPToken indexed _JPToken,
        address indexed _underlyingToken,
        address indexed _wrappedToken,
        uint256 _underlyingQuantity,
        uint256 _wrappedQuantity,
        string _integrationName
    );

    /* ============ State Variables ============ */

    // Mapping of JPToken to Issuance hook configurations
    mapping(IJPToken => IManagerIssuanceHook) public managerIssuanceHook;
    // Mapping of asset to exchange execution parameters
    mapping(IERC20 => string) public exchangeInfo;
    // Mapping of asset to wrap execution parameters
    mapping(IERC20 => WrapExecutionParams) public wrapInfo;
    // Wrapped ETH address
    IWETH public immutable weth;

    /* ============ Constructor ============ */

    /**
     * Set state controller state variable
     */
    constructor(IController _controller, IWETH _weth) public ModuleBase(_controller) {
        weth = _weth;
    }

    /* ============ External Functions ============ */

    /**
     * Issue JPToken with a specified amount of a single token.
     *
     * @param _JPToken              Instance of the JPToken contract
     * @param _issueToken           Address of the issue token
     * @param _issueTokenQuantity   Quantity of the issue token
     * @param _slippage             Percentage of single token reserved to handle slippage
     * @param _to                   Address to mint JPToken to
     * @param _returnDust           If to return left component
     */
    function issueWithSingleToken(
        IJPToken _JPToken,
        address _issueToken,
        uint256 _issueTokenQuantity,
        uint256 _slippage,
        address _to,
        bool _returnDust
    )
        external
        nonReentrant
        onlyValidAndInitializedJP(_JPToken)
    {
        require(_issueTokenQuantity > 0, "Issue token quantity must be > 0");
        // Transfer the specified issue token to JPToken
        transferFrom(
            IERC20(_issueToken),
            msg.sender,
            address(_JPToken),
            _issueTokenQuantity
        );

        uint256 issueTokenRemain = _issueWithSingleToken(_JPToken, _issueToken, _issueTokenQuantity, _slippage, _to, _returnDust);

        // transfer the remaining issue token to issuer
        _JPToken.strictInvokeTransfer(
            _issueToken,
            msg.sender,
            issueTokenRemain
        );
    }

    /**
     * Issue JPToken with a specified amount of ETH.
     *
     * @param _JPToken              Instance of the JPToken amount
     * @param _slippage             Percentage of single token reserved to handle slippage
     * @param _to                   Address to mint JPToken to
     * @param _returnDust           If to return left component
     */
    function issueWithEther(
        IJPToken _JPToken,
        uint256 _slippage,
        address _to,
        bool _returnDust
    )
        external
        payable
        nonReentrant
        onlyValidAndInitializedJP(_JPToken)
    {
        require(msg.value > 0, "Issue ether quantity must be > 0");
        weth.deposit{ value: msg.value }();
        // Transfer the specified weth to JPToken
        transferFrom(
            weth,
            address(this),
            address(_JPToken),
            msg.value
        );
        uint256 issueTokenRemain = _issueWithSingleToken(_JPToken, address(weth), msg.value, _slippage, _to, _returnDust);
        // transfer the remaining weth to issuer
        _JPToken.strictInvokeTransfer(
            address(weth),
            msg.sender,
            issueTokenRemain
        );
    }

    /**
     * Issue JPToken with a specified amount of Eth. 
     *
     * @param _JPToken              Instance of the JPToken contract
     * @param _minJPTokenRec        The minimum amount of JPToken to receive
     * @param _weightings           Eth distribution for each component
     * @param _to                   Address to mint JPToken to
     * @param _returnDust           If to return left components
     */
    function issueWithEther2(
        IJPToken _JPToken,
        uint256 _minJPTokenRec,
        uint256[] memory _weightings,
        address _to,
        bool _returnDust
    )         
        external
        payable
        nonReentrant
        onlyValidAndInitializedJP(_JPToken) 
    {
        require(msg.value > 0, "Issue ether quantity must be > 0");
        weth.deposit{ value: msg.value }();
        // Transfer the specified weth to JPToken
        transferFrom(
            weth,
            address(this),
            address(_JPToken),
            msg.value
        );
        uint256 issueTokenRemain = _issueWithSingleToken2(_JPToken, address(weth), msg.value, _minJPTokenRec, _weightings, _to, _returnDust);
        // transfer the remaining weth to issuer
        _JPToken.strictInvokeTransfer(
            address(weth),
            msg.sender,
            issueTokenRemain
        );
    }

    /**
     * Issue JPToken with a specified amount of a single asset with specification
     *
     * @param _JPToken              Instance of the JPToken contract
     * @param _issueToken           token used to issue with
     * @param _issueTokenQuantity   amount of issue tokens
     * @param _minJPTokenRec        The minimum amount of JPToken to receive
     * @param _weightings           Eth distribution for each component
     * @param _to                   Address to mint JPToken to
     * @param _returnDust           If to return left components
     */
    function issueWithSingleToken2 (
        IJPToken _JPToken,
        address _issueToken,
        uint256 _issueTokenQuantity,
        uint256 _minJPTokenRec,
        uint256[] memory _weightings,  // percentage in 18 decimals and order should follow JPComponents get from a JP token
        address _to,
        bool _returnDust
    )   
        external
        nonReentrant
        onlyValidAndInitializedJP(_JPToken) 
    {
        require(_issueTokenQuantity > 0, "Issue token quantity must be > 0");
        // Transfer the specified issue token to JPToken
        transferFrom(
            IERC20(_issueToken),
            msg.sender,
            address(_JPToken),
            _issueTokenQuantity
        );        
        
        uint256 issueTokenRemain = _issueWithSingleToken2(_JPToken, _issueToken, _issueTokenQuantity, _minJPTokenRec, _weightings, _to, _returnDust);
        // transfer the remaining weth to issuer
        _JPToken.strictInvokeTransfer(
            address(_issueToken),
            msg.sender,
            issueTokenRemain
        );
        
    }

    /**
     * Burns a user's JPToken of specified quantity, unwinds external positions, and exchange components
     * to the specified token and return to the specified address. Does not work for debt/negative external positions.
     *
     * @param _JPToken             Instance of the JPToken contract
     * @param _JPTokenQuantity     Quantity of the JPToken to redeem
     * @param _redeemToken         Address of redeem token
     * @param _to                  Address to redeem JPToken to
     * @param _minRedeemTokenToRec Minimum redeem to to receive
     */
    function redeemToSingleToken(
        IJPToken _JPToken,
        uint256 _JPTokenQuantity,
        address _redeemToken,
        address _to,
        uint256 _minRedeemTokenToRec
    )
        external
        nonReentrant
        onlyValidAndInitializedJP(_JPToken)
    {
        require(_JPTokenQuantity > 0, "Redeem quantity must be > 0");
        _JPToken.burn(msg.sender, _JPTokenQuantity);

        (
            address[] memory components,
            uint256[] memory componentQuantities
        ) = getRequiredComponentIssuanceUnits(_JPToken, _JPTokenQuantity, false);
        uint256 totalRedeemTokenAcquired = 0;
        for (uint256 i = 0; i < components.length; i++) {
            _executeExternalPositionHooks(_JPToken, _JPTokenQuantity, IERC20(components[i]), false);
            uint256 redeemTokenAcquired = _exchangeDefaultPositionsToRedeemToken(_JPToken, _redeemToken, components[i], componentQuantities[i]);
            totalRedeemTokenAcquired = totalRedeemTokenAcquired.add(redeemTokenAcquired);
        }

        require(totalRedeemTokenAcquired >= _minRedeemTokenToRec, "_minRedeemTokenToRec not met");

        _JPToken.strictInvokeTransfer(
            _redeemToken,
            _to,
            totalRedeemTokenAcquired
        );

        emit JPTokenRedeemed(address(_JPToken), msg.sender, _to, _JPTokenQuantity);
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
     * Removes this module from the JPToken, via call by the JPToken. Left with empty logic
     * here because there are no cheJP needed to verify removal.
     */
    function removeModule() external override {}

    /**
     * OWNER ONLY: Set exchange for passed components of the JPToken. Can be called at anytime.
     *
     * @param _components           Array of components
     * @param _exchangeNames        Array of exchange names mapping to correct component
     */
    function setExchanges(
        address[] memory _components,
        string[] memory _exchangeNames
    )
        external
        onlyOwner
    {
        _components.validatePairsWithArray(_exchangeNames);

        for (uint256 i = 0; i < _components.length; i++) {
            require(
                controller.getIntegrationRegistry().isValidIntegration(address(this), _exchangeNames[i]),
                "Unrecognized exchange name"
            );

            exchangeInfo[IERC20(_components[i])] = _exchangeNames[i];
            emit AssetExchangeExecutionParamUpdated(_components[i], _exchangeNames[i]);
        }
    }

    /**
     * OWNER ONLY: Set wrap adapters for passed components of the JPToken. Can be called at anytime.
     *
     * @param _components           Array of components
     * @param _wrapAdapterNames     Array of wrap adapter names mapping to correct component
     * @param _underlyingTokens     Array of underlying tokens mapping to correct component
     */
    function setWrapAdapters(
        address[] memory _components,
        string[] memory _wrapAdapterNames,
        address[] memory _underlyingTokens
    )
    external
    onlyOwner
    {
        _components.validatePairsWithArray(_wrapAdapterNames);
        _components.validatePairsWithArray(_underlyingTokens);

        for (uint256 i = 0; i < _components.length; i++) {
            require(
                controller.getIntegrationRegistry().isValidIntegration(address(this), _wrapAdapterNames[i]),
                "Unrecognized wrap adapter name"
            );

            wrapInfo[IERC20(_components[i])].wrapAdapterName = _wrapAdapterNames[i];
            wrapInfo[IERC20(_components[i])].underlyingToken = _underlyingTokens[i];
            emit AssetWrapExecutionParamUpdated(_components[i], _wrapAdapterNames[i], _underlyingTokens[i]);
        }
    }

    /**
     * Retrieves the addresses and units required to issue/redeem a particular quantity of JPToken.
     *
     * @param _JPToken             Instance of the JPToken to issue
     * @param _quantity             Quantity of JPToken to issue
     * @param _isIssue              Boolean whether the quantity is issuance or redemption
     * @return address[]            List of component addresses
     * @return uint256[]            List of component units required for a given JPToken quantity
     */
    function getRequiredComponentIssuanceUnits(
        IJPToken _JPToken,
        uint256 _quantity,
        bool _isIssue
    )
        public
        view
        returns (address[] memory, uint256[] memory)
    {
        (
            address[] memory components,
            uint256[] memory issuanceUnits
        ) = _getTotalIssuanceUnits(_JPToken);

        uint256[] memory notionalUnits = new uint256[](components.length);
        for (uint256 i = 0; i < issuanceUnits.length; i++) {
            // Use preciseMulCeil to round up to ensure overcollateration when small issue quantities are provided
            // and preciseMul to round down to ensure overcollateration when small redeem quantities are provided
            notionalUnits[i] = _isIssue ? 
                issuanceUnits[i].preciseMulCeil(_quantity) : 
                issuanceUnits[i].preciseMul(_quantity);
            require(notionalUnits[i] > 0, "component amount should not be zero");
        }

        return (components, notionalUnits);
    }

    /* ============ Internal Functions ============ */

    /**
     * Issue JPToken with a specified amount of a single token.
     *
     * @param _JPToken              Instance of the JPToken contract
     * @param _issueToken           Address of the issue token
     * @param _issueTokenQuantity   Quantity of the issue token
     * @param _slippage             Percentage of single token reserved to handle slippage
     * @param _to                   Address to mint JPToken to
     */
    function _issueWithSingleToken(
        IJPToken _JPToken,
        address _issueToken,
        uint256 _issueTokenQuantity,
        uint256 _slippage,
        address _to,
        bool _returnDust
    )
        internal
        returns(uint256)
    {
        // Calculate how many JPTokens can be issued with the specified amount of issue token
        // Get valuation of the JPToken with the quote asset as the issue token. Returns value in precise units (1e18)
        // Reverts if price is not found
        uint256 JPTokenValuation = controller.getJPValuer().calculateJPTokenValuation(_JPToken, _issueToken);
        uint256 JPTokenQuantity = _issueTokenQuantity.preciseDiv(uint256(10).safePower(uint256(ERC20(_issueToken).decimals()))).preciseMul(PreciseUnitMath.preciseUnit().sub(_slippage)).preciseDiv(JPTokenValuation);
        address hookContract = _callPreIssueHooks(_JPToken, JPTokenQuantity, msg.sender, _to);
        // Get components and required notional amount to issue JPTokens    
        (uint256 JPTokenQuantityToMint, uint256 issueTokenRemain)= _tradeAndWrapComponents(_JPToken, _issueToken, _issueTokenQuantity, JPTokenQuantity, _returnDust);
        _JPToken.mint(_to, JPTokenQuantityToMint);

        emit JPTokenIssued(address(_JPToken), msg.sender, _to, hookContract, JPTokenQuantityToMint, issueTokenRemain);
        return issueTokenRemain;
    }

    /**
     * This is a internal implementation for issue JPToken with a specified amount of a single asset with specification. 
     *
     * @param _JPToken              Instance of the JPToken contract
     * @param _issueToken           token used to issue with
     * @param _issueTokenQuantity   amount of issue tokens
     * @param _minJPTokenRec        The minimum amount of JPToken to receive
     * @param _weightings           Eth distribution for each component
     * @param _to                   Address to mint JPToken to
     * @param _returnDust           If to return left components
     */
    function _issueWithSingleToken2(   
        IJPToken _JPToken,
        address _issueToken,
        uint256 _issueTokenQuantity,
        uint256 _minJPTokenRec,
        uint256[] memory _weightings,
        address _to,
        bool _returnDust
    ) 
        internal 
        returns(uint256)
    {
        address hookContract = _callPreIssueHooks(_JPToken, _minJPTokenRec, msg.sender, _to);
        address[] memory components = _JPToken.getComponents();
        require(components.length == _weightings.length, "weightings mismatch");
        (uint256 maxJPTokenToIssue, uint256 returnedIssueToken) = _issueWithSpec(_JPToken, _issueToken, _issueTokenQuantity, components, _weightings, _returnDust);
        require(maxJPTokenToIssue >= _minJPTokenRec, "_minJPTokenRec not met");

        _JPToken.mint(_to, maxJPTokenToIssue);

        emit JPTokenIssued(address(_JPToken), msg.sender, _to, hookContract, maxJPTokenToIssue, returnedIssueToken);        
        
        return returnedIssueToken;
    }

    function _issueWithSpec(IJPToken _JPToken, address _issueToken, uint256 _issueTokenQuantity, address[] memory components, uint256[] memory _weightings, bool _returnDust) 
        internal 
        returns(uint256, uint256)
    {
        uint256 maxJPTokenToIssue = PreciseUnitMath.MAX_UINT_256;
        uint256[] memory componentTokenReceiveds = new uint256[](components.length);

        for (uint256 i = 0; i < components.length; i++) {
            uint256 _issueTokenAmountToUse = _issueTokenQuantity.preciseMul(_weightings[i]).sub(1); // avoid underflow
            uint256 componentRealUnitRequired = (_JPToken.getDefaultPositionRealUnit(components[i])).toUint256();
            uint256 componentReceived = _tradeAndWrapComponents2(_JPToken, _issueToken, _issueTokenAmountToUse, components[i]);
            componentTokenReceiveds[i] = componentReceived;
            // guarantee issue JP token amount.
            uint256 maxIssue = componentReceived.preciseDiv(componentRealUnitRequired);
            if (maxIssue <= maxJPTokenToIssue) {
                maxJPTokenToIssue = maxIssue;
            }
        }   

        uint256 issueTokenToReturn = _dustToReturn(_JPToken, _issueToken, componentTokenReceiveds, maxJPTokenToIssue, _returnDust);
 
        return (maxJPTokenToIssue, issueTokenToReturn);
    }

    function _tradeAndWrapComponents2(IJPToken _JPToken, address _issueToken, uint256 _issueTokenAmountToUse, address _component) internal returns(uint256) {
        uint256 componentTokenReceived;
        if (_issueToken == _component) {
            componentTokenReceived = _issueTokenAmountToUse;     
        } else if (wrapInfo[IERC20(_component)].underlyingToken == address(0)) {
            // For underlying tokens, exchange directly
            (, componentTokenReceived) = _trade(_JPToken, _issueToken, _component, _issueTokenAmountToUse, true);
        } else {
            // For wrapped tokens, exchange to underlying tokens first and then wrap it
            WrapExecutionParams memory wrapExecutionParams = wrapInfo[IERC20(_component)];
            IWrapAdapter wrapAdapter = IWrapAdapter(getAndValidateAdapter(wrapExecutionParams.wrapAdapterName));
            uint256 underlyingReceived = 0;
            if (wrapExecutionParams.underlyingToken == wrapAdapter.ETH_TOKEN_ADDRESS()) {
                if (_issueToken != address(weth)) {
                    (, underlyingReceived) = _trade(_JPToken, _issueToken, address(weth), _issueTokenAmountToUse, true);
                } else {
                    underlyingReceived = _issueTokenAmountToUse;
                }
                componentTokenReceived = _wrap(_JPToken, wrapExecutionParams.underlyingToken, _component, underlyingReceived, wrapExecutionParams.wrapAdapterName, true);
            } else {
                (, underlyingReceived) = _trade(_JPToken, _issueToken, wrapExecutionParams.underlyingToken, _issueTokenAmountToUse, true);
                componentTokenReceived = _wrap(_JPToken, wrapExecutionParams.underlyingToken, _component, underlyingReceived, wrapExecutionParams.wrapAdapterName, false);
            }
        }

        return componentTokenReceived;
    }
    

    function _tradeAndWrapComponents(IJPToken _JPToken, address _issueToken, uint256 issueTokenRemain, uint256 JPTokenQuantity, bool _returnDust)
        internal
        returns(uint256, uint256)
    {
        (
        address[] memory components,
        uint256[] memory componentQuantities
        ) = getRequiredComponentIssuanceUnits(_JPToken, JPTokenQuantity, true);
        // Transform the issue token to each components
        uint256 issueTokenSpent;
        uint256 componentTokenReceived;
        uint256 minIssuePercentage = 10 ** 18;
        uint256[] memory componentTokenReceiveds = new uint256[](components.length);

        for (uint256 i = 0; i < components.length; i++) {
            (issueTokenSpent, componentTokenReceived) = _exchangeIssueTokenToDefaultPositions(_JPToken, _issueToken, components[i], componentQuantities[i]);
            require(issueTokenRemain >= issueTokenSpent, "Not enough issue token remaining");
            issueTokenRemain = issueTokenRemain.sub(issueTokenSpent);
            _executeExternalPositionHooks(_JPToken, JPTokenQuantity, IERC20(components[i]), true);

            // guarantee issue JP token amount.
            uint256 issuePercentage = componentTokenReceived.preciseDiv(componentQuantities[i]);
            if (issuePercentage <= minIssuePercentage) {
                minIssuePercentage = issuePercentage;
            }
            componentTokenReceiveds[i] = componentTokenReceived;
        }

        uint256 maxJPTokenToIssue = JPTokenQuantity.preciseMul(minIssuePercentage);
        issueTokenRemain = issueTokenRemain.add(_dustToReturn(_JPToken, _issueToken, componentTokenReceiveds, maxJPTokenToIssue, _returnDust));

        return (maxJPTokenToIssue, issueTokenRemain);
    }

    /**
     * Swap remaining component baJP to issue token.
     */
    function _dustToReturn(IJPToken _JPToken, address _issueToken, uint256[] memory componentTokenReceiveds, uint256 maxJPTokenToIssue, bool _returnDust) internal returns(uint256) {
        if (!_returnDust) {
            return 0;
        }
        uint256 issueTokenToReturn = 0;
        address[] memory components = _JPToken.getComponents();

        for(uint256 i = 0; i < components.length; i++) {
            uint256 requiredComponentUnit = ((_JPToken.getDefaultPositionRealUnit(components[i])).toUint256()).preciseMul(maxJPTokenToIssue);
            uint256 toReturn = componentTokenReceiveds[i].sub(requiredComponentUnit);
            uint256 diffPercentage = toReturn.preciseDiv(requiredComponentUnit); // percentage in 18 decimals
            if (diffPercentage > (PreciseUnitMath.preciseUnit().div(10000))) { // 0.01%
                issueTokenToReturn = issueTokenToReturn.add(_exchangeDefaultPositionsToRedeemToken(_JPToken, _issueToken, components[i], toReturn));
            }
        }     

        return issueTokenToReturn;
    }    

    /**
     * Retrieves the component addresses and list of total units for components. This will revert if the external unit
     * is ever equal or less than 0 .
     */
    function _getTotalIssuanceUnits(IJPToken _JPToken) internal view returns (address[] memory, uint256[] memory) {
        address[] memory components = _JPToken.getComponents();
        uint256[] memory totalUnits = new uint256[](components.length);

        for (uint256 i = 0; i < components.length; i++) {
            address component = components[i];
            int256 cumulativeUnits = _JPToken.getDefaultPositionRealUnit(component);

            address[] memory externalModules = _JPToken.getExternalPositionModules(component);
            if (externalModules.length > 0) {
                for (uint256 j = 0; j < externalModules.length; j++) {
                    int256 externalPositionUnit = _JPToken.getExternalPositionRealUnit(component, externalModules[j]);

                    require(externalPositionUnit > 0, "Only positive external unit positions are supported");

                    cumulativeUnits = cumulativeUnits.add(externalPositionUnit);
                }
            }

            totalUnits[i] = cumulativeUnits.toUint256();
        }

        return (components, totalUnits);        
    }

    /**
     * If a pre-issue hook has been configured, call the external-protocol contract. Pre-issue hook logic
     * can contain arbitrary logic including validations, external function calls, etc.
     * Note: All modules with external positions must implement ExternalPositionIssueHooks
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

    /**
     * For each component's external module positions, calculate the total notional quantity, and 
     * call the module's issue hook or redeem hook.
     * Note: It is possible that these hooks can cause the states of other modules to change.
     * It can be problematic if the a hook called an external function that called baJP into a module, resulting in state inconsistencies.
     */
    function _executeExternalPositionHooks(
        IJPToken _JPToken,
        uint256 _JPTokenQuantity,
        IERC20 _component,
        bool isIssue
    )
        internal
    {
        address[] memory externalPositionModules = _JPToken.getExternalPositionModules(address(_component));
        for (uint256 i = 0; i < externalPositionModules.length; i++) {
            if (isIssue) {
                IModuleIssuanceHook(externalPositionModules[i]).componentIssueHook(_JPToken, _JPTokenQuantity, _component, true);
            } else {
                IModuleIssuanceHook(externalPositionModules[i]).componentRedeemHook(_JPToken, _JPTokenQuantity, _component, true);
            }
        }
    }

    function _exchangeIssueTokenToDefaultPositions(IJPToken _JPToken, address _issueToken, address _component, uint256 _componentQuantity) internal returns(uint256, uint256) {
        uint256 issueTokenSpent;
        uint256 componentTokenReceived;
        if (_issueToken == _component) {
            // continue if issue token is component token
            issueTokenSpent = _componentQuantity;
            componentTokenReceived = _componentQuantity;
        } else if (wrapInfo[IERC20(_component)].underlyingToken == address(0)) {
            // For underlying tokens, exchange directly
            (issueTokenSpent, componentTokenReceived) = _trade(_JPToken, _issueToken, _component, _componentQuantity, false);
        } else {
            // For wrapped tokens, exchange to underlying tokens first and then wrap it
            WrapExecutionParams memory wrapExecutionParams = wrapInfo[IERC20(_component)];
            IWrapAdapter wrapAdapter = IWrapAdapter(getAndValidateAdapter(wrapExecutionParams.wrapAdapterName));
            uint256 underlyingTokenQuantity = wrapAdapter.getDepositUnderlyingTokenAmount(wrapExecutionParams.underlyingToken, _component, _componentQuantity);
            if (wrapExecutionParams.underlyingToken == wrapAdapter.ETH_TOKEN_ADDRESS()) {
                if (_issueToken != address(weth)) {
                    (issueTokenSpent, ) = _trade(_JPToken, _issueToken, address(weth), underlyingTokenQuantity, false);
                } else {
                    issueTokenSpent = underlyingTokenQuantity;
                }
                componentTokenReceived = _wrap(_JPToken, wrapExecutionParams.underlyingToken, _component, underlyingTokenQuantity, wrapExecutionParams.wrapAdapterName, true);
            } else {
                (issueTokenSpent,) = _trade(_JPToken, _issueToken, wrapExecutionParams.underlyingToken, underlyingTokenQuantity, false);
                componentTokenReceived = _wrap(_JPToken, wrapExecutionParams.underlyingToken, _component, underlyingTokenQuantity, wrapExecutionParams.wrapAdapterName, false);
            }
        }
        return (issueTokenSpent, componentTokenReceived);
    }

    function _exchangeDefaultPositionsToRedeemToken(IJPToken _JPToken, address _redeemToken, address _component, uint256 _componentQuantity) internal returns(uint256) {
        uint256 redeemTokenAcquired;
        if (_redeemToken == _component) {
            // continue if redeem token is component token
            redeemTokenAcquired = _componentQuantity;
        } else if (wrapInfo[IERC20(_component)].underlyingToken == address(0)) {
            // For underlying tokens, exchange directly
            
            (, redeemTokenAcquired) = _trade(_JPToken, _component, _redeemToken, _componentQuantity, true);
        } else {
            // For wrapped tokens, unwrap it and exchange underlying tokens to redeem tokens
            WrapExecutionParams memory wrapExecutionParams = wrapInfo[IERC20(_component)];
            IWrapAdapter wrapAdapter = IWrapAdapter(getAndValidateAdapter(wrapExecutionParams.wrapAdapterName));

            (uint256 underlyingReceived, uint256 unwrappedAmount) = 
            _unwrap(_JPToken, wrapExecutionParams.underlyingToken, _component, _componentQuantity, wrapExecutionParams.wrapAdapterName, wrapExecutionParams.underlyingToken == wrapAdapter.ETH_TOKEN_ADDRESS());

            if (wrapExecutionParams.underlyingToken == wrapAdapter.ETH_TOKEN_ADDRESS()) {
                (, redeemTokenAcquired) = _trade(_JPToken, address(weth), _redeemToken, underlyingReceived, true);                
            } else {
                (, redeemTokenAcquired) = _trade(_JPToken, wrapExecutionParams.underlyingToken, _redeemToken, underlyingReceived, true);                
            }    
        }
        return redeemTokenAcquired;
    }

    /**
     * Take snapshot of JPToken's balance of underlying and wrapped tokens.
     */
    function _snapshotTargetTokenBalance(
        IJPToken _JPToken,
        address _targetToken
    ) internal view returns(uint256) {
        uint256 targetTokenBalance = IERC20(_targetToken).balanceOf(address(_JPToken));
        return (targetTokenBalance);
    }

    /**
     * Validate post trade data.
     *
     * @param _tradeInfo                Struct containing trade information used in internal functions
     */
    function _validatePostTrade(TradeInfo memory _tradeInfo) internal view returns (uint256) {
        uint256 exchangedQuantity = IERC20(_tradeInfo.receiveToken)
        .balanceOf(address(_tradeInfo.JPToken))
        .sub(_tradeInfo.preTradeReceiveTokenBalance);

        require(
            exchangedQuantity >= _tradeInfo.totalReceiveQuantity, "Slippage too big"
        );
        return exchangedQuantity;
    }

    /**
     * Validate pre trade data. CheJP exchange is valid, token quantity is valid.
     *
     * @param _tradeInfo            Struct containing trade information used in internal functions
     */
    function _validatePreTradeData(TradeInfo memory _tradeInfo) internal view {
        require(_tradeInfo.totalSendQuantity > 0, "Token to sell must be nonzero");
        uint256 sendTokenBalance = IERC20(_tradeInfo.sendToken).balanceOf(address(_tradeInfo.JPToken));
        require(
            sendTokenBalance >= _tradeInfo.totalSendQuantity,
            "total send quantity cant be greater than existing"
        );
    }

    /**
     * Create and return TradeInfo struct
     *
     * @param _JPToken              Instance of the JPToken to trade
     * @param _exchangeAdapter      The exchange adapter in the integrations registry
     * @param _sendToken            Address of the token to be sent to the exchange
     * @param _receiveToken         Address of the token that will be received from the exchange
     * @param _exactQuantity        Exact token quantity during trade
     * @param _isSendTokenFixed     Indicate if the send token is fixed
     *
     * return TradeInfo             Struct containing data for trade
     */
    function _createTradeInfo(
        IJPToken _JPToken,
        IExchangeAdapter _exchangeAdapter,
        address _sendToken,
        address _receiveToken,
        uint256 _exactQuantity,
        bool _isSendTokenFixed
    )
        internal
        view
        returns (TradeInfo memory)
    {
        uint256 thresholdAmount;
        address[] memory path;
        if (_sendToken == address(weth) || _receiveToken == address(weth)) {
            path = new address[](2);
            path[0] = _sendToken;
            path[1] = _receiveToken;
            // uint256[] memory thresholdAmounts = _isSendTokenFixed ? _exchangeAdapter.getMinAmountsOut(_exactQuantity, path) : _exchangeAdapter.getMaxAmountsIn(_exactQuantity, path);
            // thresholdAmount = _isSendTokenFixed ? thresholdAmounts[1] : thresholdAmounts[0];
        } else {
            path = new address[](3);
            path[0] = _sendToken;
            path[1] = address(weth);
            path[2] = _receiveToken;
            // uint256[] memory thresholdAmounts = _isSendTokenFixed ? _exchangeAdapter.getMinAmountsOut(_exactQuantity, path) : _exchangeAdapter.getMaxAmountsIn(_exactQuantity, path);
            // thresholdAmount = _isSendTokenFixed ? thresholdAmounts[2] : thresholdAmounts[0];
        }

        TradeInfo memory tradeInfo;
        tradeInfo.JPToken = _JPToken;
        tradeInfo.exchangeAdapter = _exchangeAdapter;
        tradeInfo.sendToken = _sendToken;
        tradeInfo.receiveToken = _receiveToken;
        tradeInfo.totalSendQuantity =  _exactQuantity;
        tradeInfo.totalReceiveQuantity = 0;
        tradeInfo.preTradeSendTokenBalance = _snapshotTargetTokenBalance(_JPToken, _sendToken);
        tradeInfo.preTradeReceiveTokenBalance = _snapshotTargetTokenBalance(_JPToken, _receiveToken);
        tradeInfo.data = _isSendTokenFixed ? _exchangeAdapter.generateDataParam(path, true) : _exchangeAdapter.generateDataParam(path, false);
        return tradeInfo;
    }

    /**
     * Calculate the exchange execution price based on send and receive token amount.
     *
     * @param _sendToken            Address of the token to be sent to the exchange
     * @param _receiveToken         Address of the token that will be received from the exchange
     * @param _isSendTokenFixed     Indicate if the send token is fixed
     * @param _exactQuantity        Exact token quantity during trade
     * @param _thresholdAmount      Max/Min amount of token to send/receive
     *
     * return uint256               Exchange execution price
     */
    function _calculateExchangeExecutionPrice(address _sendToken, address _receiveToken, bool _isSendTokenFixed,
        uint256 _exactQuantity, uint256 _thresholdAmount) internal view returns (uint256)
    {
        uint256 sendQuantity = _isSendTokenFixed ? _exactQuantity : _thresholdAmount;
        uint256 receiveQuantity = _isSendTokenFixed ? _thresholdAmount : _exactQuantity;
        uint256 normalizedSendQuantity = sendQuantity.preciseDiv(uint256(10).safePower(uint256(ERC20(_sendToken).decimals())));
        uint256 normalizedReceiveQuantity = receiveQuantity.preciseDiv(uint256(10).safePower(uint256(ERC20(_receiveToken).decimals())));
        return normalizedReceiveQuantity.preciseDiv(normalizedSendQuantity);
    }

    /**
     * Invoke approve for send token, get method data and invoke trade in the context of the JPToken.
     *
     * @param _JPToken              Instance of the JPToken to trade
     * @param _exchangeAdapter      Exchange adapter in the integrations registry
     * @param _sendToken            Address of the token to be sent to the exchange
     * @param _receiveToken         Address of the token that will be received from the exchange
     * @param _sendQuantity         Units of token in JPToken sent to the exchange
     * @param _receiveQuantity      Units of token in JPToken received from the exchange
     * @param _data                 Arbitrary bytes to be used to construct trade call data
     */
    function _executeTrade(
        IJPToken _JPToken,
        IExchangeAdapter _exchangeAdapter,
        address _sendToken,
        address _receiveToken,
        uint256 _sendQuantity,
        uint256 _receiveQuantity,
        bytes memory _data
    )
        internal
    {
        // Get spender address from exchange adapter and invoke approve for exact amount on JPToken
        _JPToken.invokeApprove(
            _sendToken,
            _exchangeAdapter.getSpender(),
            _sendQuantity
        );

        (
            address targetExchange,
            uint256 callValue,
            bytes memory methodData
        ) = _exchangeAdapter.getTradeCalldata(
            _sendToken,
            _receiveToken,
            address(_JPToken),
            _sendQuantity,
            _receiveQuantity,
            _data
        );

        _JPToken.invoke(targetExchange, callValue, methodData);
    }

    /**
     * Executes a trade on a supported DEX.
     *
     * @param _JPToken              Instance of the JPToken to trade
     * @param _sendToken            Address of the token to be sent to the exchange
     * @param _receiveToken         Address of the token that will be received from the exchange
     * @param _exactQuantity        Exact Quantity of token in JPToken to be sent or received from the exchange
     * @param _isSendTokenFixed     Indicate if the send token is fixed
     */
    function _trade(
        IJPToken _JPToken,
        address _sendToken,
        address _receiveToken,
        uint256 _exactQuantity,
        bool _isSendTokenFixed
    )
        internal
        returns (uint256, uint256)
    {
        if (address(_sendToken) == address(_receiveToken)) {
            return (_exactQuantity, _exactQuantity);
        }
        TradeInfo memory tradeInfo = _createTradeInfo(
            _JPToken,
            IExchangeAdapter(getAndValidateAdapter(exchangeInfo[IERC20(_receiveToken)])),
            _sendToken,
            _receiveToken,
            _exactQuantity,
            _isSendTokenFixed
        );
        _validatePreTradeData(tradeInfo);
        _executeTrade(tradeInfo.JPToken, tradeInfo.exchangeAdapter, tradeInfo.sendToken, tradeInfo.receiveToken, tradeInfo.totalSendQuantity, tradeInfo.totalReceiveQuantity, tradeInfo.data);
        _validatePostTrade(tradeInfo);
        uint256 totalSendQuantity = tradeInfo.preTradeSendTokenBalance.sub(_snapshotTargetTokenBalance(_JPToken, _sendToken));
        uint256 totalReceiveQuantity = _snapshotTargetTokenBalance(_JPToken, _receiveToken).sub(tradeInfo.preTradeReceiveTokenBalance);
        emit ComponentExchanged(
            _JPToken,
            _sendToken,
            _receiveToken,
            tradeInfo.exchangeAdapter,
            totalSendQuantity,
            totalReceiveQuantity
        );
        return (totalSendQuantity, totalReceiveQuantity);
    }

    /**
     * Instructs the JPToken to wrap an underlying asset into a wrappedToken via a specified adapter.
     *
     * @param _JPToken              Instance of the JPToken
     * @param _underlyingToken      Address of the component to be wrapped
     * @param _wrappedToken         Address of the desired wrapped token
     * @param _underlyingQuantity   Quantity of underlying tokens to wrap
     * @param _integrationName      Name of wrap module integration (mapping on integration registry)
     */
    function _wrap(
        IJPToken _JPToken,
        address _underlyingToken,
        address _wrappedToken,
        uint256 _underlyingQuantity,
        string memory _integrationName,
        bool _usesEther
    )
        internal
        returns (uint256)
    {
        (
        uint256 notionalUnderlyingWrapped,
        uint256 notionalWrapped
        ) = _validateAndWrap(
            _integrationName,
            _JPToken,
            _underlyingToken,
            _wrappedToken,
            _underlyingQuantity,
            _usesEther // does not use Ether
        );

        emit ComponentWrapped(
            _JPToken,
            _underlyingToken,
            _wrappedToken,
            notionalUnderlyingWrapped,
            notionalWrapped,
            _integrationName
        );
        return notionalWrapped;
    }

    /**
     * MANAGER-ONLY: Instructs the JPToken to unwrap a wrapped asset into its underlying via a specified adapter.
     *
     * @param _JPToken              Instance of the JPToken
     * @param _underlyingToken      Address of the underlying asset
     * @param _wrappedToken         Address of the component to be unwrapped
     * @param _wrappedQuantity      Quantity of wrapped tokens in Position units
     * @param _integrationName      ID of wrap module integration (mapping on integration registry)
     */
    function _unwrap(
        IJPToken _JPToken,
        address _underlyingToken,
        address _wrappedToken,
        uint256 _wrappedQuantity,
        string memory _integrationName,
        bool _usesEther
    )
        internal returns (uint256, uint256)
    {
        (
        uint256 notionalUnderlyingUnwrapped,
        uint256 notionalUnwrapped
        ) = _validateAndUnwrap(
            _integrationName,
            _JPToken,
            _underlyingToken,
            _wrappedToken,
            _wrappedQuantity,
            _usesEther // uses Ether
        );

        emit ComponentUnwrapped(
            _JPToken,
            _underlyingToken,
            _wrappedToken,
            notionalUnderlyingUnwrapped,
            notionalUnwrapped,
            _integrationName
        );

        return (notionalUnderlyingUnwrapped, notionalUnwrapped);
    }

    /**
     * The WrapModule approves the underlying to the 3rd party
     * integration contract, then invokes the JPToken to call wrap by passing its calldata along. When raw ETH
     * is being used (_usesEther = true) WETH position must first be unwrapped and underlyingAddress sent to
     * adapter must be external protocol's ETH representative address.
     *
     * Returns notional amount of underlying tokens and wrapped tokens that were wrapped.
     */
    function _validateAndWrap(
        string memory _integrationName,
        IJPToken _JPToken,
        address _underlyingToken,
        address _wrappedToken,
        uint256 _underlyingQuantity,
        bool _usesEther
    )
        internal
        returns (uint256, uint256)
    {
        uint256 preActionUnderlyingNotional;
        // Snapshot pre wrap balances
        uint256 preActionWrapNotional = _snapshotTargetTokenBalance(_JPToken, _wrappedToken);

        IWrapAdapter wrapAdapter = IWrapAdapter(getAndValidateAdapter(_integrationName));

        address snapshotToken = _usesEther ? address(weth) : _underlyingToken;
        _validateInputs(_JPToken, snapshotToken, _underlyingQuantity);
        preActionUnderlyingNotional = _snapshotTargetTokenBalance(_JPToken, snapshotToken);

        // Execute any pre-wrap actions depending on if using raw ETH or not
        if (_usesEther) {
            _JPToken.invokeUnwrapWETH(address(weth), _underlyingQuantity);
        } else {
            address spender = wrapAdapter.getWrapSpenderAddress(_underlyingToken, _wrappedToken);
            _JPToken.invokeApprove(_underlyingToken, spender, _underlyingQuantity.add(1));
        }

        // Get function call data and invoke on JPToken
        _createWrapDataAndInvoke(
            _JPToken,
            wrapAdapter,
            _usesEther ? wrapAdapter.ETH_TOKEN_ADDRESS() : _underlyingToken,
            _wrappedToken,
            _underlyingQuantity
        );

        // Snapshot post wrap balances
        uint256 postActionUnderlyingNotional = _snapshotTargetTokenBalance(_JPToken, snapshotToken);
        uint256 postActionWrapNotional = _snapshotTargetTokenBalance(_JPToken, _wrappedToken);
        return (
            preActionUnderlyingNotional.sub(postActionUnderlyingNotional),
            postActionWrapNotional.sub(preActionWrapNotional)
        );
    }

    /**
     * The WrapModule calculates the total notional wrap token to unwrap, then invokes the JPToken to call
     * unwrap by passing its calldata along. When raw ETH is being used (_usesEther = true) underlyingAddress
     * sent to adapter must be set to external protocol's ETH representative address and ETH returned from
     * external protocol is wrapped.
     *
     * Returns notional amount of underlying tokens and wrapped tokens unwrapped.
     */
    function _validateAndUnwrap(
        string memory _integrationName,
        IJPToken _JPToken,
        address _underlyingToken,
        address _wrappedToken,
        uint256 _wrappedTokenQuantity,
        bool _usesEther
    )
        internal
        returns (uint256, uint256)
    {
        _validateInputs(_JPToken, _wrappedToken, _wrappedTokenQuantity);

        // Snapshot pre wrap balance
        address snapshotToken = _usesEther ? address(weth) : _underlyingToken;
        uint256 preActionUnderlyingNotional = _snapshotTargetTokenBalance(_JPToken, snapshotToken);
        uint256 preActionWrapNotional = _snapshotTargetTokenBalance(_JPToken, _wrappedToken);

        IWrapAdapter wrapAdapter = IWrapAdapter(getAndValidateAdapter(_integrationName));
        address unWrapSpender = wrapAdapter.getUnwrapSpenderAddress(_underlyingToken, _wrappedToken);
        _JPToken.invokeApprove(_wrappedToken, unWrapSpender, _wrappedTokenQuantity);
        
        // Get function call data and invoke on JPToken
        _createUnwrapDataAndInvoke(
            _JPToken,
            wrapAdapter,
            _usesEther ? wrapAdapter.ETH_TOKEN_ADDRESS() : _underlyingToken,
            _wrappedToken,
            _wrappedTokenQuantity
        );

        // immediately wrap to WTH after getting baJP ETH
        if (_usesEther) {
            _JPToken.invokeWrapWETH(address(weth), address(_JPToken).balance);
        }
        
        // Snapshot post wrap balances
        uint256 postActionUnderlyingNotional = _snapshotTargetTokenBalance(_JPToken, snapshotToken);
        uint256 postActionWrapNotional = _snapshotTargetTokenBalance(_JPToken, _wrappedToken);
        return (
            postActionUnderlyingNotional.sub(preActionUnderlyingNotional),
            preActionWrapNotional.sub(postActionWrapNotional)
        );
    }

    /**
     * Validates the wrap operation is valid. In particular, the following cheJPs are made:
     * - The position is Default
     * - The position has sufficient units given the transact quantity
     * - The transact quantity > 0
     *
     * It is expected that the adapter will cheJP if wrappedToken/underlyingToken are a valid pair for the given
     * integration.
     */
    function _validateInputs(
        IJPToken _JPToken,
        address _component,
        uint256 _quantity
    )
        internal
        view
    {
        require(_quantity > 0, "component quantity must be > 0");
        require(_snapshotTargetTokenBalance(_JPToken, _component) >= _quantity, "quantity cant be greater than existing");
    }

    /**
     * Create the calldata for wrap and then invoke the call on the JPToken.
     */
    function _createWrapDataAndInvoke(
        IJPToken _JPToken,
        IWrapAdapter _wrapAdapter,
        address _underlyingToken,
        address _wrappedToken,
        uint256 _notionalUnderlying
    ) internal {
        (
            address callTarget,
            uint256 callValue,
            bytes memory callByteData
        ) = _wrapAdapter.getWrapCallData(
            _underlyingToken,
            _wrappedToken,
            _notionalUnderlying
        );

        _JPToken.invoke(callTarget, callValue, callByteData);
    }

    /**
     * Create the calldata for unwrap and then invoke the call on the JPToken.
     */
    function _createUnwrapDataAndInvoke(
        IJPToken _JPToken,
        IWrapAdapter _wrapAdapter,
        address _underlyingToken,
        address _wrappedToken,
        uint256 _notionalUnderlying
    ) internal {
        (
            address callTarget,
            uint256 callValue,
            bytes memory callByteData
        ) = _wrapAdapter.getUnwrapCallData(
            _underlyingToken,
            _wrappedToken,
            _notionalUnderlying
        );

        _JPToken.invoke(callTarget, callValue, callByteData);
    }
}
