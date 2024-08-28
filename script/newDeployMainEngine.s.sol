// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import {Script} from "forge-std/Script.sol";
// import {console} from "forge-std/console.sol";
// import {MainEngine} from "../src/MainEngine.sol";
// import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
// import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
// import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
// import {WETH9} from "../test/mocks/Weth9Mock.sol";

// contract DeployMainEngine is Script {
//     struct DeploymentInfo {
//         address factory;
//         address nonfungiblePositionManager;
//         address swapRouter;
//         address WETH9;
//         address tokenDescriptor;
//         uint256 chainId;
//     }

//     DeploymentInfo public info;

//     function run() external returns (MainEngine, DeploymentInfo memory) {
//         console.log("Starting DeployMainEngine script");

//         info.chainId = block.chainid;
//         console.log("Chain ID:", info.chainId);

//         uint256 deployerPrivateKey;
//         if (info.chainId == 31337) {
//             deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
//             console.log("Using Anvil private key");
//         } else if (info.chainId == 11155111) {
//             deployerPrivateKey = vm.envUint("SEPOLIA_PRIVATE_KEY");
//             console.log("Using Sepolia private key");
//         } else {
//             revert("Unsupported chain ID");
//         }

//         vm.startBroadcast(deployerPrivateKey);

//         if (info.chainId == 31337) {
//             deployAndTestAnvilContracts();
//         } else if (info.chainId == 11155111) {
//             setAndTestSepoliaAddresses();
//         }

//         MainEngine mainEngine = new MainEngine(
//             IUniswapV3Factory(info.factory),
//             INonfungiblePositionManager(info.nonfungiblePositionManager),
//             ISwapRouter(info.swapRouter),
//             info.WETH9
//         );
//         console.log("MainEngine deployed at:", address(mainEngine));
//         testMainEngine(mainEngine);

//         logDeploymentInfo();

//         vm.stopBroadcast();
//         console.log("DeployMainEngine script completed");
//         return (mainEngine, info);
//     }

//     function deployAndTestAnvilContracts() internal {
//         console.log("Deploying and testing on Anvil (Chain ID: 31337)");

//         // Deploy and test WETH9
//         WETH9 weth9 = new WETH9();
//         info.WETH9 = address(weth9);
//         testWETH9(weth9);

//         // Deploy and test UniswapV3Factory
//         info.factory = deployFromArtifact("abi-artifacts/UniswapV3Factory.json", "");
//         testUniswapV3Factory(IUniswapV3Factory(info.factory));

//         // Deploy TokenDescriptor
//         bytes32 nativeCurrencyLabelBytes = bytes32("ETH");
//         info.tokenDescriptor = deployFromArtifact(
//             "abi-artifacts/NonfungibleTokenPositionDescriptor.json", 
//             abi.encode(info.WETH9, nativeCurrencyLabelBytes)
//         );

//         // Deploy and test NonfungiblePositionManager
//         info.nonfungiblePositionManager = deployFromArtifact(
//             "abi-artifacts/NonfungiblePositionManager.json", 
//             abi.encode(info.factory, info.WETH9, info.tokenDescriptor)
//         );
//         testNonfungiblePositionManager(INonfungiblePositionManager(info.nonfungiblePositionManager));

//         // Deploy and test SwapRouter
//         info.swapRouter = deployFromArtifact(
//             "abi-artifacts/SwapRouter.json", 
//             abi.encode(info.factory, info.WETH9)
//         );
//         testSwapRouter(ISwapRouter(info.swapRouter));
//     }

//     function setAndTestSepoliaAddresses() internal {
//         console.log("Setting and testing predefined addresses for Sepolia (Chain ID: 11155111)");
//         info.factory = address(0x1F98431c8aD98523631AE4a59f267346ea31F984);
//         info.nonfungiblePositionManager = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
//         info.swapRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);
//         info.WETH9 = address(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
//         info.tokenDescriptor = address(0x42B24A95702b9986e82d421cC3568932790A48Ec);

//         testWETH9(WETH9(info.WETH9));
//         testUniswapV3Factory(IUniswapV3Factory(info.factory));
//         testNonfungiblePositionManager(INonfungiblePositionManager(info.nonfungiblePositionManager));
//         testSwapRouter(ISwapRouter(info.swapRouter));
//     }

//     function testWETH9(WETH9 weth) internal {
//         uint256 depositAmount = 1 ether;
//         weth.deposit{value: depositAmount}();
//         require(weth.balanceOf(address(this)) == depositAmount, "WETH9 deposit failed");
//         weth.withdraw(depositAmount);
//         require(weth.balanceOf(address(this)) == 0, "WETH9 withdrawal failed");
//         console.log("WETH9 test passed");
//     }

//     function testUniswapV3Factory(IUniswapV3Factory factory) internal {
//         require(factory.owner() != address(0), "Factory owner not set");
//         console.log("UniswapV3Factory test passed");
//     }

//     function testNonfungiblePositionManager(INonfungiblePositionManager npm) internal {
//         require(npm.factory() == info.factory, "NPM factory address mismatch");
//         require(npm.WETH9() == info.WETH9, "NPM WETH9 address mismatch");
//         console.log("NonfungiblePositionManager test passed");
//     }

//     function testSwapRouter(ISwapRouter router) internal {
//         require(address(router) != address(0), "SwapRouter address is zero");
//         // Additional checks can be added here if the SwapRouter has public readable state
//         console.log("SwapRouter test passed");
//     }

//     function testMainEngine(MainEngine mainEngine) internal {
//         require(address(mainEngine.factory()) == info.factory, "MainEngine factory mismatch");
//         require(address(mainEngine.positionManager()) == info.nonfungiblePositionManager, "MainEngine NPM mismatch");
//         require(address(mainEngine.router()) == info.swapRouter, "MainEngine router mismatch");
//         require(mainEngine.WETH9() == info.WETH9, "MainEngine WETH9 mismatch");
//         console.log("MainEngine test passed");
//     }

//     function deployFromArtifact(string memory artifactPath, bytes memory constructorArgs) internal returns (address) {
//         bytes memory bytecode = vm.parseJson(vm.readFile(artifactPath), ".bytecode");
//         return deployContract(bytecode, constructorArgs);
//     }

//     function deployContract(bytes memory bytecode, bytes memory args) internal returns (address) {
//         address deployedAddress;
//         assembly {
//             deployedAddress := create(0, add(bytecode, 0x20), mload(bytecode))
//             if iszero(deployedAddress) { revert(0, 0) }
//         }

//         if (args.length > 0) {
//             (bool success,) = deployedAddress.call(args);
//             require(success, "Constructor call failed");
//         }

//         return deployedAddress;
//     }

//     function logDeploymentInfo() internal view {
//         console.log("Deployment Info:");
//         console.log("- Factory:", info.factory);
//         console.log("- NonfungiblePositionManager:", info.nonfungiblePositionManager);
//         console.log("- SwapRouter:", info.swapRouter);
//         console.log("- WETH9:", info.WETH9);
//         console.log("- TokenDescriptor:", info.tokenDescriptor);
//         console.log("- Chain ID:", info.chainId);
//     }
// }