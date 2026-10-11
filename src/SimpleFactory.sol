// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal CREATE2 factory for deterministic hook deployment.
/// @dev Deploy once, then call deploy(salt, initcode). Mine the salt for THIS
///      contract's address (not the EOA).
contract SimpleFactory {
    event Deployed(address addr, bytes32 salt);

    function deploy(bytes32 salt, bytes memory initCode) external returns (address addr) {
        assembly {
            addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(addr != address(0), "create2 failed");
        emit Deployed(addr, salt);
    }
}
