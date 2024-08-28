// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CustomToken} from "./CustomToken.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract MainEngine is Ownable {
    uint256 public constant MIN_CREATE_COST = 0.01 ether;
    uint256 public constant LIQUIDITY_LOCK_PERIOD = 3 days;

    mapping(address => address) public tokenCreator;
    mapping(address => bool) public isTokenCreated;
    mapping(address => bool) public initialLiquidityAdded;
    mapping(address => uint256) public tokenToPositionId;
    mapping(address => uint256) public tokenToLockedLiquidityPercentage;
    mapping(address => uint256) public tokenToWithdrawableLiquidity;
    mapping(address => uint256) public tokenCreationTime;
    uint256 public accumulatedFees;

    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    ISwapRouter public immutable swapRouter;
    address public immutable WETH9;

    uint24 public constant poolFee = 3000; // 0.3%

    mapping(address => address) public tokenToPool;
    mapping(address => uint256) public tokenToLiquidity;

    event TokenCreated(
        address indexed tokenAddress,
        address indexed creator,
        string name,
        string symbol,
        uint256 initialSupply,
        uint256 lockedLiquidityPercentage
    );
    event PoolCreated(address indexed token, address indexed pool);
    event LiquidityAdded(address indexed token, address indexed provider, uint256 amount);
    event Swapped(address indexed token, address indexed user, uint256 amountIn, uint256 amountOut);
    event LiquidityWithdrawn(address indexed token, address indexed provider, uint256 amount);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    error InsufficientETHSent();
    error TokenNotCreated();
    error NotAuthorized();
    error PoolAlreadyExists();
    error PoolDoesNotExist();
    error InsufficientETHProvided();
    error MustSendETH();
    error InitialLiquidityAlreadyAdded();
    error InvalidInitialSupply();
    error InvalidLockedLiquidityPercentage();
    error InsufficientWithdrawableLiquidity();
    error WithdrawalTooEarly();

    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        ISwapRouter _swapRouter,
        address _WETH9
    ) Ownable(msg.sender) {
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
        WETH9 = _WETH9;
    }

    modifier onlyTokenCreator(address tokenAddress) {
        if (msg.sender != tokenCreator[tokenAddress]) revert NotAuthorized();
        _;
    }

    modifier tokenExists(address tokenAddress) {
        if (!isTokenCreated[tokenAddress]) revert TokenNotCreated();
        _;
    }

    function createTokenAndAddLiquidity(
        string memory name,
        string memory symbol,
        string memory description,
        string memory imageUrl,
        uint256 initialSupply,
        uint256 lockedLiquidityPercentage
    ) external payable returns (address tokenAddress) {
        if (msg.value < MIN_CREATE_COST) revert InsufficientETHSent();
        if (initialSupply == 0) revert InvalidInitialSupply();
        if (lockedLiquidityPercentage > 100) revert InvalidLockedLiquidityPercentage();

        tokenAddress = _createToken(name, symbol, description, imageUrl, initialSupply);

        tokenToLockedLiquidityPercentage[tokenAddress] = lockedLiquidityPercentage;
        tokenCreationTime[tokenAddress] = block.timestamp;

        _setupPool(tokenAddress);
        _addInitialLiquidity(tokenAddress, initialSupply, msg.value);

        return tokenAddress;
    }

    function _createToken(
        string memory name,
        string memory symbol,
        string memory description,
        string memory imageUrl,
        uint256 initialSupply
    ) internal returns (address tokenAddress) {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        tokenAddress = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                type(CustomToken).creationCode,
                abi.encode(name, symbol, description, imageUrl, msg.sender, initialSupply)
            )
        );

        tokenCreator[tokenAddress] = msg.sender;
        isTokenCreated[tokenAddress] = true;

        emit TokenCreated(
            tokenAddress, msg.sender, name, symbol, initialSupply, tokenToLockedLiquidityPercentage[tokenAddress]
        );

        return tokenAddress;
    }
    //tested

    function createTokenOnly(
        string memory name,
        string memory symbol,
        string memory description,
        string memory imageUrl,
        uint256 initialSupply
    ) external returns (address tokenAddress) {
        if (initialSupply == 0) revert InvalidInitialSupply();

        tokenAddress = _createToken(name, symbol, description, imageUrl, initialSupply);

        return tokenAddress;
    }

    function _setupPool(address tokenAddress) internal {
        if (tokenToPool[tokenAddress] != address(0)) revert PoolAlreadyExists();

        address token0 = tokenAddress < WETH9 ? tokenAddress : WETH9;
        address token1 = tokenAddress < WETH9 ? WETH9 : tokenAddress;

        try factory.createPool(token0, token1, poolFee) returns (address pool) {
            tokenToPool[tokenAddress] = pool;
            emit PoolCreated(tokenAddress, pool);
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Pool creation failed: ", reason)));
        } catch {
            revert("Pool creation failed with unknown error");
        }
    }

    function _addInitialLiquidity(address tokenAddress, uint256 tokenAmount, uint256 ethAmount)
        internal
        onlyTokenCreator(tokenAddress)
    {
        if (initialLiquidityAdded[tokenAddress]) revert InitialLiquidityAlreadyAdded();

        TransferHelper.safeApprove(tokenAddress, address(nonfungiblePositionManager), tokenAmount);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: tokenAddress,
            token1: WETH9,
            fee: poolFee,
            tickLower: getMinTick(poolFee),
            tickUpper: getMaxTick(poolFee),
            amount0Desired: tokenAmount,
            amount1Desired: ethAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint128 liquidity,,) = nonfungiblePositionManager.mint{value: ethAmount}(params);

        tokenToPositionId[tokenAddress] = tokenId;
        tokenToLiquidity[tokenAddress] = liquidity;
        initialLiquidityAdded[tokenAddress] = true;

        uint256 withdrawableLiquidity = (liquidity * (100 - tokenToLockedLiquidityPercentage[tokenAddress])) / 100;
        tokenToWithdrawableLiquidity[tokenAddress] = withdrawableLiquidity;

        emit LiquidityAdded(tokenAddress, msg.sender, liquidity);
    }

    function withdrawLiquidity(address tokenAddress, uint256 amount)
        external
        tokenExists(tokenAddress)
        onlyTokenCreator(tokenAddress)
    {
        if (block.timestamp < tokenCreationTime[tokenAddress] + LIQUIDITY_LOCK_PERIOD) revert WithdrawalTooEarly();
        if (amount > tokenToWithdrawableLiquidity[tokenAddress]) revert InsufficientWithdrawableLiquidity();

        tokenToWithdrawableLiquidity[tokenAddress] -= amount;

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: tokenToPositionId[tokenAddress],
            liquidity: uint128(amount),
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });

        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.decreaseLiquidity(params);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenToPositionId[tokenAddress],
            recipient: msg.sender,
            amount0Max: uint128(amount0),
            amount1Max: uint128(amount1)
        });

        nonfungiblePositionManager.collect(collectParams);

        emit LiquidityWithdrawn(tokenAddress, msg.sender, amount);
    }

    function swapExactTokensForETH(address tokenAddress, uint256 tokenAmount, uint256 minETHOut)
        external
        tokenExists(tokenAddress)
    {
        TransferHelper.safeTransferFrom(tokenAddress, msg.sender, address(this), tokenAmount);
        TransferHelper.safeApprove(tokenAddress, address(swapRouter), tokenAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenAddress,
            tokenOut: WETH9,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: tokenAmount,
            amountOutMinimum: minETHOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle(params);
        uint256 contractFee = amountOut / 100; // 1% fee
        uint256 userAmount = amountOut - contractFee;

        (bool success,) = msg.sender.call{value: userAmount}("");
        require(success, "ETH transfer failed");

        accumulatedFees += contractFee;

        emit Swapped(tokenAddress, msg.sender, tokenAmount, amountOut);
    }

    function swapExactETHForTokens(address tokenAddress, uint256 minTokensOut)
        external
        payable
        tokenExists(tokenAddress)
    {
        if (msg.value == 0) revert MustSendETH();

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH9,
            tokenOut: tokenAddress,
            fee: poolFee,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: msg.value,
            amountOutMinimum: minTokensOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle{value: msg.value}(params);
        uint256 contractFee = amountOut / 100;
        accumulatedFees += contractFee;

        IERC20(tokenAddress).transfer(msg.sender, amountOut - contractFee);

        emit Swapped(tokenAddress, msg.sender, msg.value, amountOut - contractFee);
    }

    function withdrawFees(uint256 amount) external onlyOwner {
        require(amount <= accumulatedFees, "Insufficient accumulated fees");
        accumulatedFees -= amount;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Fee withdrawal failed");
        emit FeesWithdrawn(msg.sender, amount);
    }

    function getTokenPrice(address tokenAddress) external view tokenExists(tokenAddress) returns (uint256) {
        address pool = tokenToPool[tokenAddress];
        if (pool == address(0)) revert PoolDoesNotExist();
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        return uint256(sqrtPriceX96) ** 2 * 1e18 / 2 ** 192;
    }

    function getMinTick(uint24) public pure returns (int24) {
        return -887272;
    }

    function getMaxTick(uint24) public pure returns (int24) {
        return 887272;
    }

    // Getter functions
    function getTokenCreator(address tokenAddress) external view returns (address) {
        return tokenCreator[tokenAddress];
    }

    function getIsTokenCreated(address tokenAddress) external view returns (bool) {
        return isTokenCreated[tokenAddress];
    }

    function getInitialLiquidityAdded(address tokenAddress) external view returns (bool) {
        return initialLiquidityAdded[tokenAddress];
    }

    function getTokenToPositionId(address tokenAddress) external view returns (uint256) {
        return tokenToPositionId[tokenAddress];
    }

    function getTokenToLockedLiquidityPercentage(address tokenAddress) external view returns (uint256) {
        return tokenToLockedLiquidityPercentage[tokenAddress];
    }

    function getTokenToWithdrawableLiquidity(address tokenAddress) external view returns (uint256) {
        return tokenToWithdrawableLiquidity[tokenAddress];
    }

    function getTokenCreationTime(address tokenAddress) external view returns (uint256) {
        return tokenCreationTime[tokenAddress];
    }

    function getTokenToPool(address tokenAddress) external view returns (address) {
        return tokenToPool[tokenAddress];
    }

    function getTokenToLiquidity(address tokenAddress) external view returns (uint256) {
        return tokenToLiquidity[tokenAddress];
    }

    // Tester functions
    function testTokenCreation(
        string memory name,
        string memory symbol,
        string memory description,
        string memory imageUrl,
        uint256 initialSupply
    ) external returns (address) {
        return _createToken(name, symbol, description, imageUrl, initialSupply);
    }

    function testPoolSetup(address tokenAddress) external {
        _setupPool(tokenAddress);
    }

    function testAddInitialLiquidity(address tokenAddress, uint256 tokenAmount) external payable {
        _addInitialLiquidity(tokenAddress, tokenAmount, msg.value);
    }

    receive() external payable {}
}
