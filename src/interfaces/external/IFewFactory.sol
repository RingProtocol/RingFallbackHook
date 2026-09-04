// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Ring's FewFactory -- maps original ERC20 addresses to their deployed fewToken counterparts.
/// @dev Minimal ABI subset consumed by the hook and burner.
interface IFewFactory {
    /// @notice Returns the fewToken for `originalToken`, or address(0) if none deployed.
    function getWrappedToken(address originalToken) external view returns (address wrappedToken);
}
