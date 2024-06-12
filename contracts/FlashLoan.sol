// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.6.6;

// Uniswap interface and library imports
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IERC20.sol";
import "./libraries/UniswapV2Library.sol";
import "./libraries/SafeERC20.sol";
import "hardhat/console.sol";

contract FlashLoan {
     using SafeERC20 for IERC20;
    // Factory and Routing Addresses
    address private constant UNISWAP_FACTORY =
        0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address private constant UNISWAP_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    address private constant SUSHISWAP_FACTORY =
        0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
    address private constant SUSHISWAP_ROUTER =
        0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;            

    // Token Addresses
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    uint256 private deadline = block.timestamp + 1 days;
    uint256 private constant MAX_INT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;
    
    function checkResult(uint _repayAmount,uint _acquiredCoin) pure private returns(bool){
        return _acquiredCoin>_repayAmount;
    }
    
     // GET CONTRACT BALANCE
    // Allows public view of balance for contract
    function getBalanceOfToken(address _address) public view returns (uint256) {
        return IERC20(_address).balanceOf(address(this));
    }


    function placeTrade(address _fromToken,address _toToken,uint _amountIn, address factory, address router) private returns(uint){
        address pair = IUniswapV2Factory(factory).getPair(
            _fromToken,
            _toToken
        );
        require(pair != address(0), "Pool does not exist");

        // Calculate Amount Out
        address[] memory path = new address[](2);
        path[0] = _fromToken;
        path[1] = _toToken;

        uint256 amountRequired = IUniswapV2Router01(router)
            .getAmountsOut(_amountIn, path)[1];

    
        uint256 amountReceived = IUniswapV2Router01(router)
            .swapExactTokensForTokens(
                _amountIn, 
                amountRequired, 
                path,
                address(this),
                deadline 
            )[1];


        require(amountReceived > 0, "Transaction Abort");

        return amountReceived;
    }

    function initateArbitrage(address _usdcBorrow,uint _amount) external{
         IERC20(WETH).safeApprove(address(UNISWAP_ROUTER),MAX_INT);
         IERC20(USDC).safeApprove(address(UNISWAP_ROUTER),MAX_INT);
         IERC20(LINK).safeApprove(address(UNISWAP_ROUTER),MAX_INT);

         IERC20(WETH).safeApprove(address(SUSHISWAP_ROUTER),MAX_INT);
         IERC20(USDC).safeApprove(address(SUSHISWAP_ROUTER),MAX_INT);
         IERC20(LINK).safeApprove(address(SUSHISWAP_ROUTER),MAX_INT);
         
         //liquidity pool of USDC and WETH
         address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(
            _usdcBorrow,
            WETH
         );

         require(pair!=address(0),"Pool does not exist");
         
         address token0 = IUniswapV2Pair(pair).token0();//WBNB
         address token1 = IUniswapV2Pair(pair).token1();//BUSD

         uint amount0Out = _usdcBorrow==token0?_amount:0;
         uint amount1Out = _usdcBorrow==token1?_amount:0; //BUSD Amount
         
         bytes memory data = abi.encode(_usdcBorrow,_amount,msg.sender);
         IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }

    function uniswapV2Call(
        address _sender,
        uint256 _amount0,
        uint256 _amount1,
        bytes calldata _data
    ) external {
        // Ensure this request came from the contract
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(
            token0,
            token1
        );
        require(msg.sender == pair, "The sender needs to match the pair");
        require(_sender == address(this), "Sender should match the contract");

        // Decode data for calculating the repayment
        (address usdcBorrow, uint256 amount, address myAddress) = abi.decode(
            _data,
            (address, uint256, address)
        );

        // Calculate the amount to repay at the end
        uint256 fee = ((amount * 3) / 997) + 1;
        uint256 repayAmount = amount + fee;

        // DO ARBITRAGE

        // Assign loan amount
        uint256 loanAmount = _amount0 > 0 ? _amount0 : _amount1;

        // Place Trades
        uint256 trade1Coin = placeTrade(USDC, LINK, loanAmount, UNISWAP_FACTORY,UNISWAP_ROUTER);
        uint256 trade2Coin = placeTrade(LINK, USDC, trade1Coin, SUSHISWAP_FACTORY, SUSHISWAP_ROUTER);

        // Check Profitability
        bool profCheck = checkResult(repayAmount, trade2Coin);
        require(profCheck, "Arbitrage not profitable");

        // Pay Myself
        IERC20 otherToken = IERC20(USDC);
        otherToken.transfer(myAddress, trade2Coin - repayAmount);

        // Pay Loan Back
        IERC20(usdcBorrow).transfer(pair, repayAmount);
    }



}
