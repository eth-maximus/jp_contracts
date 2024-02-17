const { expect } = require("chai");
const { Signer } = require("ethers");
const { ethers, web3 } = require("hardhat");
const { factory } = require("typescript");
const BN = require("ethers").BigNumber;

function sleep(time) {
  return new Promise((resolve) => setTimeout(resolve, time));
}

describe("JP-Issue-Alpaca-Venus", async () => {
  const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
  const DEAD_ADDRESS = '0x000000000000000000000000000000000000dEaD';

  beforeEach( async () => {
    [deployer, investor] = await ethers.getSigners();
    
    accounts = await ethers.getSigners();
    provider = await ethers.provider;

    let CREATOR = await ethers.getContractFactory("JPTokenCreator");
    let CONTROLLER = await ethers.getContractFactory("Controller");
    let INTEGRATION = await ethers.getContractFactory("IntegrationRegistry");
    let TOKEN = await ethers.getContractFactory("JPToken");
    let VALUER = await ethers.getContractFactory("JPValuer");
    let ORACLE = await ethers.getContractFactory("PriceOracle");
    let ISSUANCEMODULEV2 = await ethers.getContractFactory("IssuanceModuleV2");
    let UNISWAPV2ADAPTER = await ethers.getContractFactory("UniswapV2ExchangeAdapterV2");
    let ISSUANCEMODULE = await ethers.getContractFactory("IssuanceModule");
    let BASICISSUANCE = await ethers.getContractFactory("BasicIssuanceModule");
    let ALPACA = await ethers.getContractFactory("AlpacaLendingAdapter");
    let VENUS = await ethers.getContractFactory("VenusWrapAdapter");
    let ERC20 = await ethers.getContractFactory("ERC20");
    WETH9 = await ethers.getContractFactory("WETH9");

    weth = await WETH9.attach("0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c");
    bep20Usdt = "0x55d398326f99059ff775485246999027b3197955";
    venusUsdt = "0xfd5840cd36d94d7229439859c0112a4185bc0255";
    alpacaUsdt = "0x158da805682bdc8ee32d52833ad41e74bb951e59";
    wBnb = "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c";
    bUsd = "0xe9e7cea3dedca5984780bafc599bd69add087d56";

    bUsdWhale = await ethers.getImpersonatedSigner("0x67bA82904d8036c72F8cAFAc5718e58e2EF92f39");
    bUsdContract = ERC20.attach(bUsd);
    let whaleBalance = await bUsdContract.balanceOf(bUsdWhale.address);
    console.log("whale balance", whaleBalance);

    let pancakeRouter = "0x10ED43C718714eb63d5aA57B78B54704E256024E";

    let uniswapV2Adapter = await UNISWAPV2ADAPTER.deploy(pancakeRouter);
    let alpacaAdapter = await ALPACA.deploy(wBnb);
    let venusAdapter = await VENUS.deploy();
    let controller = await CONTROLLER.deploy(deployer.address);
    let creator = await CREATOR.deploy(controller.target);
    let issuanceModuleV2 = await ISSUANCEMODULEV2.deploy(controller.target, wBnb);
    let integrationRegistry = await INTEGRATION.deploy(controller.target);

    let modules = [issuanceModuleV2.target];
    let resources = [integrationRegistry.target, uniswapV2Adapter.target, alpacaAdapter.target, venusAdapter.target];
    let factories = [creator.target];
    await controller.initialize(factories, modules, resources, [0,3,4,5]);

    await integrationRegistry.addIntegration(issuanceModuleV2.target, "PANCAKESWAP", uniswapV2Adapter.target);
    await integrationRegistry.addIntegration(issuanceModuleV2.target, "VENUSADAPTER", venusAdapter.target);
    await integrationRegistry.addIntegration(issuanceModuleV2.target, "ALPACAADAPTER", alpacaAdapter.target);

    await issuanceModuleV2.setWrapAdapters([venusUsdt], ["VENUSADAPTER"], [bep20Usdt]);
    await issuanceModuleV2.setWrapAdapters([alpacaUsdt], ["ALPACAADAPTER"], [bep20Usdt]);
    await issuanceModuleV2.setExchanges([wBnb, bUsd, bep20Usdt], ["PANCAKESWAP", "PANCAKESWAP", "PANCAKESWAP"]);

    adapterComponents = [alpacaUsdt];


    let tokenComponents =[venusUsdt, alpacaUsdt];
    let tokenUnits = [2318000000,'476900000000000000'];
    let tokenModules = [issuanceModuleV2];
    await creator.create(tokenComponents, tokenUnits, tokenModules, deployer.address, "DIGITAL FUND TOKEN", "D-FUND");

    tokenAddr = await controller.jps(0);
    console.log("token addr: ", tokenAddr);
    await issuanceModuleV2.initialize(tokenAddr, ZERO_ADDRESS);

    let apprvInterface = await new ethers.Interface(["function approve(address, uint256) external returns (bool)", "function allowance(address, address) view returns (uint256)"]);
    let busdContract = await new ethers.BaseContract(bUsd, apprvInterface);
    await busdContract.connect(bUsdWhale).approve(issuanceModuleV2.target, '100000000000000000000');
    console.log("allowance : ", await busdContract.connect(bUsdWhale).allowance(bUsdWhale, issuanceModuleV2.target));
    let midTokens = ['0x0000000000000000000000000000000000000000','0x0000000000000000000000000000000000000000'];
    let weightings = ['496263495904604189', '503736504095395811'];
    await issuanceModuleV2.connect(bUsdWhale).issueWithSingleToken2(tokenAddr, bUsd, '100000000000000000000', '92204480000000000000', midTokens, weightings, bUsdWhale, false)
    
    console.log("balance of D-FUND : ", await TOKEN.attach(tokenAddr).balanceOf(bUsdWhale));
  })  


});