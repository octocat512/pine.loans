pragma solidity 0.8.3;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/WETH.sol";

interface IERC721LendingPool02 {
    function _supportedCurrency() external view returns (address);

    function borrow(
        uint256[5] memory x,
        bytes memory signature,
        bool proxy,
        address pineWallet
    ) external returns (bool);

    function repay(
        uint256 nftID,
        uint256 repayAmount,
        address pineWallet
    ) external returns (bool);
}

interface IHopRouter {
    function sendToL2(
        uint256 chainId,
        address recipient,
        uint256 amount,
        uint256 amountOutMin,
        uint256 deadline,
        address relayer,
        uint256 relayerFee
    ) external payable;
}

struct BridgeParams {
    address token;
    address recipient;
    address router;
    uint256 targetChainId;
    uint256 amount;
    uint256 destinationAmountOutMin;
    uint256 destinationDeadline;
}

contract Router01 is Ownable {
    address immutable WETHaddr;
    address payable immutable controlPlane;

    constructor(address w, address payable c) {
        WETHaddr = w;
        controlPlane = c;
    }

    uint256 fee = 0.01 ether;

    function setFee(uint256 f) public onlyOwner {
        fee = f;
    }

    function approvePool(
        address currency,
        address target,
        uint256 amount
    ) public onlyOwner {
        IERC20(currency).approve(target, amount);
    }

    function borrowETH(
        address payable target,
        uint256 valuation,
        uint256 nftID,
        uint256 loanDurationSeconds,
        uint256 expireAtBlock,
        uint256 borrowedWei,
        bytes memory signature,
        address pineWallet
    ) public {
        address currency = IERC721LendingPool02(target)._supportedCurrency();
        require(currency == WETHaddr, "only works for WETH");
        IERC721LendingPool02(target).borrow(
            [valuation, nftID, loanDurationSeconds, expireAtBlock, borrowedWei],
            signature,
            true,
            pineWallet
        );
        WETH9(payable(currency)).withdraw(IERC20(currency).balanceOf(address(this)) - fee);
        (bool success, ) = msg.sender.call{ value: address(this).balance }("");
        require(success, "cannot send ether");
        WETH9(payable(currency)).transfer(controlPlane, fee);
    }

    function borrowETHAndTeleport(
        address payable target,
        uint256 valuation,
        uint256 nftID,
        uint256 loanDurationSeconds,
        uint256 expireAtBlock,
        uint256 borrowedWei,
        bytes memory signature,
        address pineWallet,
        // hop protocol transfer params
        uint256 targetChainId // need to consider the slippage
    ) public {
        // borrowETH
        address currency = IERC721LendingPool02(target)._supportedCurrency();
        require(currency == WETHaddr, "only works for WETH");
        IERC721LendingPool02(target).borrow(
            [valuation, nftID, loanDurationSeconds, expireAtBlock, borrowedWei],
            signature,
            true,
            pineWallet
        );
        WETH9(payable(currency)).withdraw(IERC20(currency).balanceOf(address(this)) - fee);
        (bool success, ) = msg.sender.call{ value: address(this).balance }("");
        require(success, "cannot send ether");
        WETH9(payable(currency)).transfer(controlPlane, fee);

        // teleportETH ??? Which bridge should I use? hop protocol
        uint256 nativeTokenAmt = address(this).balance;

        BridgeParams memory params = BridgeParams({
            token: address(0),
            recipient: msg.sender,
            router: address(this),
            targetChainId: targetChainId,
            amount: nativeTokenAmt,
            destinationAmountOutMin: 0,
            destinationDeadline: 0
        });

        IHopRouter router = IHopRouter(params.router);

        router.sendToL2{ value: nativeTokenAmt }(
            params.targetChainId,
            params.recipient,
            params.amount,
            params.destinationAmountOutMin,
            params.destinationDeadline,
            address(0), // relayer address
            0 // relayer fee
        );
    }

    function repay(
        address payable target,
        uint256 nftID,
        uint256 repayAmount,
        address pineWallet
    ) public {
        address currency = IERC721LendingPool02(target)._supportedCurrency();
        require(IERC20(currency).transferFrom(msg.sender, address(this), repayAmount));
        IERC721LendingPool02(target).repay(nftID, repayAmount, pineWallet);
        require(IERC20(currency).transferFrom(address(this), msg.sender, IERC20(currency).balanceOf(address(this))));
    }

    function repayETH(
        address payable target,
        uint256 nftID,
        address pineWallet
    ) public payable {
        address currency = IERC721LendingPool02(target)._supportedCurrency();
        require(currency == WETHaddr, "only works for WETH");
        WETH9(payable(currency)).deposit{ value: msg.value }();
        IERC721LendingPool02(target).repay(nftID, msg.value, pineWallet);
        WETH9(payable(currency)).withdraw(IERC20(currency).balanceOf(address(this)));
        (bool success, ) = msg.sender.call{ value: address(this).balance }("");
        require(success, "cannot send ether");
    }

    receive() external payable {
        // React to receiving ether
    }

    function withdraw(uint256 amount) external onlyOwner {
        (bool success, ) = owner().call{ value: amount }("");
        require(success, "cannot send ether");
    }

    function withdrawERC20(address currency, uint256 amount) external onlyOwner {
        IERC20(currency).transfer(owner(), amount);
    }
}
