// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface Vm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert() external;
    function etch(address target, bytes calldata code) external;
    function chainId(uint256 chainId_) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "not equal");
    }

    function assertTrue(bool value) internal pure {
        require(value, "not true");
    }

    function assertLe(uint256 a, uint256 b) internal pure {
        require(a <= b, "not <=");
    }

    function assertGt(uint256 a, uint256 b) internal pure {
        require(a > b, "not >");
    }

    function assertApprox(uint256 a, uint256 b, uint256 tolerance) internal pure {
        require((a > b ? a - b : b - a) <= tolerance, "outside tolerance");
    }
}
