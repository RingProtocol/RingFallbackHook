// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

/// @notice Mock FewWrappedToken for testing. Strict 1:1 wrap/unwrap.
///         Implements minimal ERC20 so it can be approved and transferred by test routers.
contract MockFewWrappedToken is IFewWrappedToken {
    address public immutable underlying;

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address underlyingToken) {
        underlying = underlyingToken;
        name = "MockFewToken";
        symbol = "MFW";
    }

    function token() external view override returns (address) {
        return underlying;
    }

    function wrap(uint256 amount) external override returns (uint256) {
        // Pull underlying from caller.
        _transferFromUnderlying(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        return amount;
    }

    function unwrap(uint256 amount) external override returns (uint256) {
        _burn(msg.sender, amount);
        // Send underlying to caller.
        _sendUnderlying(msg.sender, amount);
        return amount;
    }

    // ---------------------------------------------------------------------
    // ERC20 (minimal, needed for approvals to liquidity router)
    // ---------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[sender][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient allowance");
            allowance[sender][msg.sender] = allowed - amount;
        }
        _transfer(sender, recipient, amount);
        return true;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _transferFromUnderlying(address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = underlying.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
    }

    function _sendUnderlying(address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            underlying.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }
}
