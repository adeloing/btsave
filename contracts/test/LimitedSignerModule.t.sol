// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LimitedSignerModule.sol";

// Mock contracts
contract MockSafe {
    mapping(address => bool) public owners;
    address public module;

    constructor() {
        owners[msg.sender] = true;
    }

    function addOwner(address owner) external { owners[owner] = true; }
    function isOwner(address owner) external view returns (bool) { return owners[owner]; }
    function getOwners() external view returns (address[] memory) {
        address[] memory o = new address[](1);
        o[0] = address(this);
        return o;
    }

    function execTransactionFromModule(
        address to, uint256 value, bytes calldata data, uint8
    ) external returns (bool) {
        (bool success,) = to.call{value: value}(data);
        return success;
    }

    // Forward calls to module as the Safe
    function callModule(address mod, bytes calldata data) external returns (bool, bytes memory) {
        return mod.call(data);
    }
}

contract MockAavePool {
    uint256 public mockHF = 2e18; // 2.0
    uint256 public mockCollateral = 500_000e8; // $500k in 8 decimals

    function setHF(uint256 hf) external { mockHF = hf; }
    function setCollateral(uint256 c) external { mockCollateral = c; }

    function getUserAccountData(address) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256
    ) {
        return (mockCollateral, 0, 0, 0, 0, mockHF);
    }
}

contract MockOracle {
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (1, 90000e8, 0, block.timestamp, 1);
    }
}

contract MockTarget {
    uint256 public value;
    function doSomething(uint256 v) external { value = v; }
}

contract LimitedSignerModuleTest is Test {
    LimitedSignerModule module;
    MockSafe safe;
    MockAavePool aavePool;
    MockOracle oracle;
    MockTarget target;

    address keeper = address(0x1111);
    address botA = address(0xA);
    address botB = address(0xB);
    address botC = address(0xC);
    address attacker = address(0x666);

    function setUp() public {
        safe = new MockSafe();
        aavePool = new MockAavePool();
        oracle = new MockOracle();
        target = new MockTarget();

        module = new LimitedSignerModule(
            address(safe),
            address(aavePool),
            address(oracle)
        );

        // Setup via Safe (simulate Safe calling the module)
        vm.startPrank(address(safe));
        module.setKeeper(keeper, true);
        module.setBot(botA, true);
        module.setBot(botB, true);
        module.setBot(botC, true);
        module.setTarget(address(target), true, bytes32(0)); // no code hash check for tests
        module.setSelector(address(target), MockTarget.doSomething.selector, true);
        vm.stopPrank();
    }

    // ===== Helper =====
    function _propose() internal returns (bytes32) {
        vm.prank(keeper);
        return module.proposeTransaction(
            address(target),
            abi.encodeWithSelector(MockTarget.doSomething.selector, 42),
            0
        );
    }

    function _approveWith2Bots(bytes32 txHash) internal {
        vm.prank(botA);
        module.approveTx(txHash);
        vm.prank(botB);
        module.approveTx(txHash);
    }

    // ===== R1: Unauthorized proposer =====
    function test_R1_UnauthorizedProposer() public {
        vm.prank(attacker);
        vm.expectRevert("LSM: unauthorized proposer");
        module.proposeTransaction(address(target), abi.encodeWithSelector(MockTarget.doSomething.selector, 1), 0);
    }

    // ===== R2: Target not whitelisted =====
    function test_R2_TargetNotWhitelisted() public {
        vm.prank(keeper);
        vm.expectRevert("LSM: target not whitelisted");
        module.proposeTransaction(address(0xBEEF), abi.encodeWithSelector(MockTarget.doSomething.selector, 1), 0);
    }

    // ===== R3: Selector not whitelisted =====
    function test_R3_SelectorNotAllowed() public {
        vm.prank(keeper);
        vm.expectRevert("LSM: function not allowed");
        module.proposeTransaction(address(target), abi.encodeWithSelector(bytes4(0xdeadbeef)), 0);
    }

    // ===== R4: Kill switch =====
    function test_R4_KillSwitch() public {
        vm.prank(address(safe));
        module.killSwitch();

        vm.prank(keeper);
        vm.expectRevert("LSM: module killed");
        module.proposeTransaction(address(target), abi.encodeWithSelector(MockTarget.doSomething.selector, 1), 0);
    }

    function test_R4_KillSwitchRevive() public {
        vm.startPrank(address(safe));
        module.killSwitch();
        assertTrue(module.killed());
        module.revive();
        assertFalse(module.killed());
        vm.stopPrank();
    }

    // ===== R5: Gas too high =====
    function test_R5_GasTooHigh() public {
        bytes32 txHash = _propose();
        _approveWith2Bots(txHash);

        vm.txGasPrice(81 gwei);
        vm.expectRevert("LSM: gas too high");
        module.executeIfReady(txHash);
    }

    // ===== R6: No raw ETH transfer =====
    function test_R6_NoRawEth() public {
        vm.prank(keeper);
        vm.expectRevert("LSM: no raw ETH transfer");
        module.proposeTransaction(address(target), abi.encodeWithSelector(MockTarget.doSomething.selector, 1), 1 ether);
    }

    // ===== R8: Insufficient signatures =====
    function test_R8_InsufficientSignatures() public {
        bytes32 txHash = _propose();
        vm.prank(botA);
        module.approveTx(txHash);

        // Only 1 approval, need 2
        vm.expectRevert("LSM: insufficient bot signatures");
        module.executeIfReady(txHash);
    }

    // ===== R8: Double approval rejected =====
    function test_R8_DoubleApproval() public {
        bytes32 txHash = _propose();
        vm.prank(botA);
        module.approveTx(txHash);

        vm.prank(botA);
        vm.expectRevert("LSM: already approved");
        module.approveTx(txHash);
    }

    // ===== R10: Cooldown =====
    function test_R10_Cooldown() public {
        vm.warp(1000);
        bytes32 txHash1 = _propose();
        _approveWith2Bots(txHash1);
        module.executeIfReady(txHash1);
        // lastExecTime = 1000

        // Propose again immediately (still at t=1000)
        bytes32 txHash2 = _propose();
        _approveWith2Bots(txHash2);

        vm.warp(1100); // only +100s, still in cooldown
        vm.expectRevert("LSM: cooldown active");
        module.executeIfReady(txHash2);

        // Advance time past cooldown
        vm.warp(1301); // 1301 - 1000 = 301 >= 300
        module.executeIfReady(txHash2); // should work
    }

    // ===== R12: Daily tx limit =====
    function test_R12_DailyTxLimit() public {
        vm.prank(address(safe));
        module.setMaxDailyTx(2);

        vm.warp(1000);
        bytes32 h1 = _propose();
        _approveWith2Bots(h1);
        module.executeIfReady(h1);

        vm.warp(1301);
        bytes32 h2 = _propose();
        _approveWith2Bots(h2);
        module.executeIfReady(h2);

        vm.warp(1602);
        bytes32 h3 = _propose();
        _approveWith2Bots(h3);
        vm.expectRevert("LSM: daily tx limit reached");
        module.executeIfReady(h3);

        // Next day — should work
        vm.warp(1000 + 1 days + 301);
        module.executeIfReady(h3);
    }

    // ===== R14: HF too low =====
    function test_R14_HFTooLow() public {
        vm.warp(block.timestamp + 301);
        aavePool.setHF(1.5e18); // Below 1.72

        bytes32 txHash = _propose();
        _approveWith2Bots(txHash);

        vm.expectRevert("LSM: HF too low");
        module.executeIfReady(txHash);
    }

    // ===== Happy path =====
    function test_HappyPath() public {
        vm.warp(block.timestamp + 301); // ensure cooldown clear
        bytes32 txHash = _propose();

        // 3 bots approve (only 2 needed)
        vm.prank(botA);
        module.approveTx(txHash);
        vm.prank(botB);
        module.approveTx(txHash);
        vm.prank(botC);
        module.approveTx(txHash);

        // Execute
        module.executeIfReady(txHash);

        // Check execution
        assertEq(target.value(), 42);

        // Check stats
        (uint256 txCount,,) = module.getDailyStats();
        assertEq(txCount, 1);
    }

    // ===== Kill switch only by Safe =====
    function test_KillSwitchOnlySafe() public {
        vm.prank(attacker);
        vm.expectRevert("LSM: only Safe");
        module.killSwitch();

        vm.prank(botA);
        vm.expectRevert("LSM: only Safe");
        module.killSwitch();
    }

    // ===== Bot rotation =====
    function test_BotRotation() public {
        address newBot = address(0xD);

        vm.prank(address(safe));
        module.rotateBotKey(botA, newBot);

        assertFalse(module.authorizedBots(botA));
        assertTrue(module.authorizedBots(newBot));
    }

    // ===== Admin functions only by Safe =====
    function test_AdminOnlySafe() public {
        vm.prank(attacker);
        vm.expectRevert("LSM: only Safe");
        module.setMaxGasPrice(100 gwei);

        vm.prank(attacker);
        vm.expectRevert("LSM: only Safe");
        module.setMinHealthFactor(2e18);

        vm.prank(attacker);
        vm.expectRevert("LSM: only Safe");
        module.setBot(attacker, true);
    }

    // ===== Unauthorized bot =====
    function test_UnauthorizedBot() public {
        bytes32 txHash = _propose();

        vm.prank(attacker);
        vm.expectRevert("LSM: unauthorized bot");
        module.approveTx(txHash);
    }

    // ===== isAllowedTransaction view =====
    function test_IsAllowedTransaction() public view {
        (bool allowed,) = module.isAllowedTransaction(
            address(target),
            abi.encodeWithSelector(MockTarget.doSomething.selector, 1),
            0
        );
        assertTrue(allowed);

        (bool notAllowed, string memory reason) = module.isAllowedTransaction(
            address(0xBEEF),
            abi.encodeWithSelector(MockTarget.doSomething.selector, 1),
            0
        );
        assertFalse(notAllowed);
        assertEq(reason, "LSM: target not whitelisted");
    }

    // ===== validateBorrow =====
    function test_ValidateBorrow() public view {
        // Within limits
        (bool ok,) = module.validateBorrow(12_480e6);
        assertTrue(ok);

        // Over step * 1.25
        (bool notOk, string memory reason) = module.validateBorrow(16_000e6);
        assertFalse(notOk);
        assertEq(reason, "LSM: borrow amount exceeded");
    }
}
