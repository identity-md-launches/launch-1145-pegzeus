// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ZeusToken} from "../src/ZeusToken.sol";

/// @title Deploy script for Pegzeus (ZEUS)
/// @notice The token has no constructor arguments and no post-deployment configuration, so the
///         whole deployment is a single `new ZeusToken()`. Whoever broadcasts receives the supply.
/// @dev On the IdentityMD launch, the factory deploys the token from its creation code (see the
///      README); this script is for local, testnet or manual deployments only. It reads no
///      environment variables: the broadcaster is whatever key `forge script` is given.
contract DeployZeusToken is Script {
    /// @notice Deploys the token. Called directly by tests; `run()` wraps it in a broadcast.
    /// @return token The deployed token. `msg.sender` of the creation holds the whole supply.
    function deploy() public returns (ZeusToken token) {
        token = new ZeusToken();
    }

    /// @notice Broadcast entry point: `forge script script/DeployZeusToken.s.sol --broadcast ...`.
    function run() external returns (ZeusToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
