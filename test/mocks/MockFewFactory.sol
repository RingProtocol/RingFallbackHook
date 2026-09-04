// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {MockFewWrappedToken} from "./MockFewWrappedToken.sol";

/// @notice Mock FewFactory for testing. Deploys a MockFewWrappedToken on demand.
contract MockFewFactory is IFewFactory {
    mapping(address origin => address wrapper) public getWrappedToken;

    function createToken(address originToken) external returns (address wrapper) {
        require(getWrappedToken[originToken] == address(0), "already created");
        wrapper = address(new MockFewWrappedToken(originToken));
        getWrappedToken[originToken] = wrapper;
    }
}
