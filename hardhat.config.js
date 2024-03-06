require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-foundry");

module.exports = {
  solidity: {
    compilers: [
      { 
        version: "0.6.10",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
        },
      },
      { 
        version: "0.6.6",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
        },
      },
      {
        version: "0.4.22",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
        },
      },
    ],
  },
  networks: {
    hardhat: {
      forking: {
        url: "https://bscrpc.com",
      },
    },
  },
};
