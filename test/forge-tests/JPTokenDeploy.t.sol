pragma solidity ^0.6.10;
pragma experimental "ABIEncoderV2";

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "contracts/protocol/JPTokenCreator.sol";
import "contracts/protocol/Controller.sol";
import "contracts/protocol/IntegrationRegistry.sol";
import "contracts/protocol/JPToken.sol";
import "contracts/protocol/modules/IssuanceModuleV2.sol";
import "contracts/protocol/integration/wrap/AlpacaLendingAdapter.sol";
import "contracts/protocol/integration/wrap/VenusWrapAdapter.sol";
import "contracts/protocol/integration/wrap/UniswapV2ExchangeAdapterV2.sol";

contract JPTokenDeployTest is Test {

    Controller controller;
    JPTokenCreator creator;
    IntegrationRegistry integrationRegistry;
    IssuanceModuleV2 issuanceModuleV2;
    AlpacaLendingAdapter alpacaLendingAdapter;
    VenusWrapAdapter venusWrapAdapter;
    UniswapV2ExchangeAdapterV2 uniswapAdapter;
    IJPToken token;

    IWETH weth = IWETH(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address pancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address bUsd = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address bUsdWhale = 0x67bA82904d8036c72F8cAFAc5718e58e2EF92f39;

    address[] factories;
    address[] modules;
    address[] resources;
    uint256[] resourceIds;

    address[] addrArr;
    address[] addrArr2;
    string[] strArr;
    int256[] intArr;
    uint256[] uintArr;

    function setUp() public {
        controller = new Controller(address(this));
        uniswapAdapter = new UniswapV2ExchangeAdapterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        alpacaLendingAdapter = new AlpacaLendingAdapter(address(weth));
        venusWrapAdapter = new VenusWrapAdapter();
        creator = new JPTokenCreator(IController(address(controller)));
        issuanceModuleV2 = new IssuanceModuleV2(IController(address(controller)), weth);
        integrationRegistry = new IntegrationRegistry(IController(address(controller)));
        factories.push(address(creator));
        modules.push(address(issuanceModuleV2));
        resources.push(address(integrationRegistry));
        resources.push(address(uniswapAdapter));
        resources.push(address(alpacaLendingAdapter));
        resources.push(address(venusWrapAdapter));
        resourceIds.push(0);
        resourceIds.push(3);
        resourceIds.push(4);
        resourceIds.push(5);
        //initialize Controller
        controller.initialize(factories, modules, resources, resourceIds);
        //set up integrations
        integrationRegistry.addIntegration(address(issuanceModuleV2), "PANCAKESWAP", address(uniswapAdapter));
        integrationRegistry.addIntegration(address(issuanceModuleV2), "ALPACAADAPTER", address(alpacaLendingAdapter));
        integrationRegistry.addIntegration(address(issuanceModuleV2), "VENUSADAPTER", address(venusWrapAdapter));
        //set up modules
        //Venus adapter
        strArr.push("VENUSADAPTER");
        addrArr.push(0xfD5840Cd36d94D7229439859C0112a4185BC0255);
        addrArr2.push(0x55d398326f99059fF775485246999027B3197955);
        issuanceModuleV2.setWrapAdapters(addrArr, strArr, addrArr2);
        delete strArr;
        delete addrArr;
        //Alpaca adapter
        strArr.push("ALPACAADAPTER");
        addrArr.push(0x158Da805682BdC8ee32d52833aD41E74bb951E59);
        issuanceModuleV2.setWrapAdapters(addrArr, strArr, addrArr2);
        delete strArr;
        //Set exchange
        strArr.push("PANCAKESWAP");
        strArr.push("PANCAKESWAP");
        addrArr2.push(bUsd);
        issuanceModuleV2.setExchanges(addrArr2, strArr);
        delete strArr;
        delete addrArr;
        delete addrArr2;
        //prep token components
        addrArr.push(0xfD5840Cd36d94D7229439859C0112a4185BC0255);
        addrArr.push(0x158Da805682BdC8ee32d52833aD41E74bb951E59);
        intArr.push(2318000000);
        intArr.push(476900000000000000);
        addrArr2.push(address(issuanceModuleV2));
        token = IJPToken(creator.create(addrArr, intArr, addrArr2, address(this), "DIGITAL FUND TOKEN", "D-FUND"));
        delete addrArr;
        delete intArr;
        delete addrArr2;
        issuanceModuleV2.initialize(token, IManagerIssuanceHook(address(0)));
        vm.prank(bUsdWhale);
        (bool success,) = bUsd.call(abi.encodeWithSelector(0x095ea7b3, address(issuanceModuleV2), 100000000000000000000));
        addrArr.push(address(0));
        addrArr.push(address(0));
        uintArr.push(496263495904604189);
        uintArr.push(503736504095395811);
    }

    function testIssue() public {
        vm.prank(bUsdWhale);
        issuanceModuleV2.issueWithSingleToken2(token, bUsd, 100000000000000000000, 91104480000000000000,
            addrArr, uintArr, bUsdWhale, false);
    }
}
