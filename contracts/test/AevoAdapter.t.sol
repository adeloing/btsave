// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AevoAdapter.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAevoRouter.sol";
import "./mocks/MockStrategy.sol";

contract AevoAdapterTest is Test {
    AevoAdapter adapter;
    MockERC20 usdc;
    MockERC20 wbtc;
    MockAevoRouter aevoRouter;
    MockStrategy strategy;

    address keeper;
    address admin;

    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_WBTC = 1e8;
    uint256 constant BTC_PRICE = 60_000e8;

    function setUp() public {
        admin = address(this);
        keeper = address(0xBEEF);

        wbtc = new MockERC20("WBTC", "WBTC", 8);
        usdc = new MockERC20("USDC", "USDC", 6);

        strategy = new MockStrategy(address(wbtc));
        strategy.setPrice(BTC_PRICE);
        strategy.setATH(BTC_PRICE);

        // Make strategy have assets for allocation check
        strategy.setTotalDeposited(100 * ONE_WBTC);

        aevoRouter = new MockAevoRouter(address(usdc));

        adapter = new AevoAdapter(
            address(aevoRouter),
            address(strategy),
            address(usdc),
            address(wbtc),
            500 * ONE_USDC // default premium limit
        );

        adapter.grantRole(adapter.KEEPER_ROLE(), keeper);

        // Fund adapter with USDC for opening puts
        usdc.mint(address(adapter), 100_000 * ONE_USDC);
    }

    // ==================== OPEN PUT ====================

    function test_openPut() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, expiry, 500 * ONE_USDC);

        assertEq(adapter.activePutCount(), 1);
        assertEq(adapter.totalAllocated(), 1000 * ONE_USDC);
    }

    function test_openPut_invalidPalier() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AevoAdapter.InvalidPalier.selector, 0));
        adapter.openPut(0, 50_000e8, 1000 * ONE_USDC, block.timestamp + 30 days, 500 * ONE_USDC);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AevoAdapter.InvalidPalier.selector, 4));
        adapter.openPut(4, 50_000e8, 1000 * ONE_USDC, block.timestamp + 30 days, 500 * ONE_USDC);
    }

    function test_openPut_alreadyActive() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, expiry, 500 * ONE_USDC);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AevoAdapter.PalierAlreadyActive.selector, 1));
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, expiry, 500 * ONE_USDC);
    }

    function test_openPut_expiryTooSoon() public {
        vm.prank(keeper);
        vm.expectRevert();
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, block.timestamp + 1 days, 500 * ONE_USDC);
    }

    function test_openPut_expiryTooFar() public {
        vm.prank(keeper);
        vm.expectRevert();
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, block.timestamp + 100 days, 500 * ONE_USDC);
    }

    function test_openPut_strikeTooHigh() public {
        vm.prank(keeper);
        vm.expectRevert();
        adapter.openPut(1, 70_000e8, 1000 * ONE_USDC, block.timestamp + 30 days, 500 * ONE_USDC);
    }

    // ==================== OPEN ALL PUTS ====================

    function test_openAllPuts() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openAllPuts(2000 * ONE_USDC, expiry, 500 * ONE_USDC);

        assertEq(adapter.activePutCount(), 2);
        // P1 = 1000 USDC, P2 = 1000 USDC
        assertEq(adapter.totalAllocated(), 2000 * ONE_USDC);
    }

    // ==================== CLOSE PUT ====================

    function test_closePut() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, expiry, 500 * ONE_USDC);

        uint8[] memory paliers = new uint8[](1);
        paliers[0] = 1;

        vm.prank(keeper);
        adapter.closePuts(paliers);

        assertEq(adapter.activePutCount(), 0);
        assertEq(adapter.totalAllocated(), 0);
    }

    function test_closePut_notActive() public {
        uint8[] memory paliers = new uint8[](1);
        paliers[0] = 1;

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AevoAdapter.PalierNotActive.selector, 1));
        adapter.closePuts(paliers);
    }

    // ==================== CLOSE ALL PUTS ====================

    function test_closeAllPuts() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openAllPuts(2000 * ONE_USDC, expiry, 500 * ONE_USDC);

        vm.prank(keeper);
        adapter.closeAllPuts();

        assertEq(adapter.activePutCount(), 0);
        assertEq(adapter.totalAllocated(), 0);
    }

    // ==================== TOTAL PUT VALUE ====================

    function test_totalPutValue() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, expiry, 500 * ONE_USDC);

        // MockAevoRouter sets initial value = collateral
        uint256 val = adapter.totalPutValue();
        assertEq(val, 1000 * ONE_USDC);
    }

    function test_totalPutValue_afterValueChange() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, expiry, 500 * ONE_USDC);

        // Get the orderId and update value
        (bytes32 orderId,,,,, ) = adapter.getPut(1);
        aevoRouter.setPositionValue(orderId, 1500 * ONE_USDC);

        assertEq(adapter.totalPutValue(), 1500 * ONE_USDC);
    }

    // ==================== GET PUT ====================

    function test_getPut() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, expiry, 500 * ONE_USDC);

        (bytes32 orderId, uint256 strike, uint256 collateral, uint256 exp, uint256 currentValue, bool active) = adapter.getPut(1);

        assertTrue(orderId != bytes32(0));
        assertEq(strike, 50_000e8);
        assertEq(collateral, 1000 * ONE_USDC);
        assertEq(exp, expiry);
        assertEq(currentValue, 1000 * ONE_USDC);
        assertTrue(active);
    }

    // ==================== ACCESS CONTROL ====================

    function test_openPut_onlyKeeper() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, block.timestamp + 30 days, 500 * ONE_USDC);
    }

    function test_closeAllPuts_onlyKeeper() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        adapter.closeAllPuts();
    }

    function test_setDefaultPremiumLimit_onlyAdmin() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        adapter.setDefaultPremiumLimit(1000 * ONE_USDC);

        adapter.setDefaultPremiumLimit(1000 * ONE_USDC);
        assertEq(adapter.defaultPremiumLimitUsdc(), 1000 * ONE_USDC);
    }

    function test_rescueUsdc_onlyAdmin() public {
        usdc.mint(address(adapter), 1000 * ONE_USDC);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        adapter.rescueUsdc(address(0xDEAD), 1000 * ONE_USDC);

        uint256 before = usdc.balanceOf(admin);
        adapter.rescueUsdc(admin, 1000 * ONE_USDC);
        assertEq(usdc.balanceOf(admin) - before, 1000 * ONE_USDC);
    }

    // ==================== ROLL DOWN ====================

    function test_rollDown() public {
        uint256 expiry = block.timestamp + 30 days;

        vm.prank(keeper);
        adapter.openPut(1, 50_000e8, 1000 * ONE_USDC, expiry, 500 * ONE_USDC);

        // Fund adapter again for reopening
        usdc.mint(address(adapter), 10_000 * ONE_USDC);

        uint256 newExpiry = block.timestamp + 60 days;
        vm.prank(keeper);
        adapter.rollDown(1, 45_000e8, newExpiry, 500 * ONE_USDC);

        // Should still be active but with new strike
        (, uint256 strike,,,,bool active) = adapter.getPut(1);
        assertEq(strike, 45_000e8);
        assertTrue(active);
    }
}
