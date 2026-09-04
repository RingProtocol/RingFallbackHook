// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Ring's FewToken interface -- strict 1:1 wrap/unwrap.
/// @dev Minimal ABI subset consumed by the hook and burner.
interface IFewWrappedToken {
    /// @return The address of the underlying ERC20.
    function token() external view returns (address);

    /// @notice Pulls `amount` of the underlying from caller, mints `amount` fewToken to caller.
    function wrap(uint256 amount) external returns (uint256);

    /// @notice Burns `amount` fewToken from caller, sends `amount` underlying to caller.
    function unwrap(uint256 amount) external returns (uint256);
}
