// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";
import {MockUSDG} from "../src/MockUSDG.sol";

contract MilestoneEscrowTest is Test {
    MilestoneEscrow esc;
    MockUSDG tok;
    address client = address(0xC1);
    address payee = address(0xF2);
    address arb = address(0xA3);
    address rando = address(0xBAD);

    uint128[] amts;
    uint64[] dls;

    function setUp() public {
        esc = new MilestoneEscrow();
        tok = new MockUSDG();
        vm.startPrank(client);
        tok.faucet(10_000e6);
        tok.approve(address(esc), type(uint256).max);
        vm.stopPrank();
        amts = [uint128(100e6), 200e6, 300e6];
        dls = [uint64(block.timestamp + 10 days), uint64(block.timestamp + 20 days), uint64(block.timestamp + 30 days)];
    }

    function _create() internal returns (uint256 id) {
        vm.prank(client);
        id = esc.createJob(payee, arb, address(tok), amts, dls);
    }

    function _createFunded() internal returns (uint256 id) {
        id = _create();
        vm.prank(client);
        esc.fund(id);
    }

    function test_createStoresJob() public {
        uint256 id = _create();
        MilestoneEscrow.Job memory j = esc.getJob(id);
        assertEq(j.client, client);
        assertEq(j.payee, payee);
        assertEq(j.total, 600e6);
        assertFalse(j.funded);
        assertEq(esc.milestoneCount(id), 3);
    }

    function test_createRevertsOnBadParams() public {
        vm.startPrank(client);
        uint128[] memory a = new uint128[](0);
        uint64[] memory d = new uint64[](0);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.createJob(payee, arb, address(tok), a, d);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.createJob(address(0), arb, address(tok), amts, dls);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.createJob(client, arb, address(tok), amts, dls);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.createJob(payee, payee, address(tok), amts, dls);
        uint64[] memory shortD = new uint64[](2);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.createJob(payee, arb, address(tok), amts, shortD);
        uint64[] memory past = new uint64[](3);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.createJob(payee, arb, address(tok), amts, past);
        vm.stopPrank();
    }

    function test_fundMovesTokens() public {
        uint256 id = _createFunded();
        assertEq(tok.balanceOf(address(esc)), 600e6);
        assertEq(tok.balanceOf(client), 10_000e6 - 600e6);
        assertTrue(esc.getJob(id).funded);
    }

    function test_fundOnlyClientAndOnce() public {
        uint256 id = _create();
        vm.prank(rando);
        vm.expectRevert(MilestoneEscrow.NotClient.selector);
        esc.fund(id);
        vm.startPrank(client);
        esc.fund(id);
        vm.expectRevert(MilestoneEscrow.AlreadyFunded.selector);
        esc.fund(id);
        vm.stopPrank();
    }

    function test_fundRevertsWithoutAllowance() public {
        vm.startPrank(client);
        tok.approve(address(esc), 0);
        uint256 id = esc.createJob(payee, arb, address(tok), amts, dls);
        vm.expectRevert();
        esc.fund(id);
        vm.stopPrank();
    }

    function test_cancelUnfundedThenCannotFund() public {
        uint256 id = _create();
        vm.startPrank(client);
        esc.cancel(id);
        vm.expectRevert(MilestoneEscrow.Cancelled.selector);
        esc.fund(id);
        vm.stopPrank();
    }

    function test_cancelFundedReverts() public {
        uint256 id = _createFunded();
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.AlreadyFunded.selector);
        esc.cancel(id);
    }

    function test_approvePaysPayee() public {
        uint256 id = _createFunded();
        vm.prank(client);
        esc.approve(id, 0);
        assertEq(tok.balanceOf(payee), 100e6);
        assertEq(uint8(esc.getMilestone(id, 0).status), uint8(MilestoneEscrow.Status.Released));
    }

    function test_approveOnlyClient() public {
        uint256 id = _createFunded();
        vm.prank(payee);
        vm.expectRevert(MilestoneEscrow.NotClient.selector);
        esc.approve(id, 0);
    }

    function test_approveTwiceReverts() public {
        uint256 id = _createFunded();
        vm.startPrank(client);
        esc.approve(id, 0);
        vm.expectRevert(MilestoneEscrow.WrongStatus.selector);
        esc.approve(id, 0);
        vm.stopPrank();
    }

    function test_approveUnfundedReverts() public {
        uint256 id = _create();
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.NotFunded.selector);
        esc.approve(id, 0);
    }

    function test_approveBadIndexReverts() public {
        uint256 id = _createFunded();
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.approve(id, 3);
    }

    function test_refundAfterDeadline() public {
        uint256 id = _createFunded();
        vm.warp(block.timestamp + 11 days);
        vm.prank(client);
        esc.refund(id, 0);
        assertEq(tok.balanceOf(client), 10_000e6 - 600e6 + 100e6);
        assertEq(uint8(esc.getMilestone(id, 0).status), uint8(MilestoneEscrow.Status.Refunded));
    }

    function test_refundBeforeDeadlineReverts() public {
        uint256 id = _createFunded();
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.DeadlineNotPassed.selector);
        esc.refund(id, 0);
    }

    function test_refundOnlyClient() public {
        uint256 id = _createFunded();
        vm.warp(block.timestamp + 11 days);
        vm.prank(payee);
        vm.expectRevert(MilestoneEscrow.NotClient.selector);
        esc.refund(id, 0);
    }

    function test_refundAfterApproveReverts() public {
        uint256 id = _createFunded();
        vm.startPrank(client);
        esc.approve(id, 0);
        vm.warp(block.timestamp + 11 days);
        vm.expectRevert(MilestoneEscrow.WrongStatus.selector);
        esc.refund(id, 0);
        vm.stopPrank();
    }

    function test_disputeBlocksRefundAndApprove() public {
        uint256 id = _createFunded();
        vm.prank(payee);
        esc.dispute(id, 0);
        vm.warp(block.timestamp + 11 days);
        vm.startPrank(client);
        vm.expectRevert(MilestoneEscrow.WrongStatus.selector);
        esc.refund(id, 0);
        vm.expectRevert(MilestoneEscrow.WrongStatus.selector);
        esc.approve(id, 0);
        vm.stopPrank();
    }

    function test_disputeOnlyParties() public {
        uint256 id = _createFunded();
        vm.prank(rando);
        vm.expectRevert(MilestoneEscrow.NotParty.selector);
        esc.dispute(id, 0);
        vm.prank(arb);
        vm.expectRevert(MilestoneEscrow.NotParty.selector);
        esc.dispute(id, 0);
    }

    function test_resolveSplit() public {
        uint256 id = _createFunded();
        vm.prank(client);
        esc.dispute(id, 1);
        vm.prank(arb);
        esc.resolve(id, 1, 150e6);
        assertEq(tok.balanceOf(payee), 150e6);
        assertEq(tok.balanceOf(client), 10_000e6 - 600e6 + 50e6);
        assertEq(uint8(esc.getMilestone(id, 1).status), uint8(MilestoneEscrow.Status.Resolved));
    }

    function test_resolveFullToEitherSide() public {
        uint256 id = _createFunded();
        vm.startPrank(client);
        esc.dispute(id, 0);
        esc.dispute(id, 1);
        vm.stopPrank();
        vm.startPrank(arb);
        esc.resolve(id, 0, 100e6);
        esc.resolve(id, 1, 0);
        vm.stopPrank();
        assertEq(tok.balanceOf(payee), 100e6);
        assertEq(tok.balanceOf(client), 10_000e6 - 600e6 + 200e6);
    }

    function test_resolveAuth_state_bounds() public {
        uint256 id = _createFunded();
        vm.prank(arb);
        vm.expectRevert(MilestoneEscrow.WrongStatus.selector);
        esc.resolve(id, 0, 0);
        vm.prank(payee);
        esc.dispute(id, 0);
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.NotArbiter.selector);
        esc.resolve(id, 0, 0);
        vm.prank(arb);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.resolve(id, 0, 100e6 + 1);
        vm.startPrank(arb);
        esc.resolve(id, 0, 50e6);
        vm.expectRevert(MilestoneEscrow.WrongStatus.selector);
        esc.resolve(id, 0, 50e6);
        vm.stopPrank();
    }

    function test_fullLifecycleEmptiesEscrow() public {
        uint256 id = _createFunded();
        vm.prank(client);
        esc.approve(id, 0);
        vm.prank(payee);
        esc.dispute(id, 1);
        vm.prank(arb);
        esc.resolve(id, 1, 120e6);
        vm.warp(block.timestamp + 31 days);
        vm.prank(client);
        esc.refund(id, 2);
        assertEq(tok.balanceOf(address(esc)), 0);
        assertEq(tok.balanceOf(payee), 220e6);
        assertEq(tok.balanceOf(client) + tok.balanceOf(payee), 10_000e6);
    }

    /// Conservation: for any sequence of actions, escrow balance == sum of Pending/Disputed milestones.
    function testFuzz_conservation(uint8 seed, uint96 a0, uint96 a1, uint96 a2) public {
        delete amts;
        amts.push(uint128(bound(a0, 1, 1000e6)));
        amts.push(uint128(bound(a1, 1, 1000e6)));
        amts.push(uint128(bound(a2, 1, 1000e6)));
        uint256 id = _createFunded();
        vm.warp(block.timestamp + 31 days);
        for (uint256 i; i < 3; ++i) {
            uint256 pick = (uint256(seed) >> (i * 2)) % 4;
            if (pick == 0) { vm.prank(client); esc.approve(id, i); }
            else if (pick == 1) { vm.prank(client); esc.refund(id, i); }
            else if (pick == 2) {
                vm.prank(payee); esc.dispute(id, i);
                vm.prank(arb); esc.resolve(id, i, uint256(seed) % (amts[i] + 1));
            }
        }
        uint256 locked;
        for (uint256 i; i < 3; ++i) {
            MilestoneEscrow.Milestone memory m = esc.getMilestone(id, i);
            if (m.status == MilestoneEscrow.Status.Pending || m.status == MilestoneEscrow.Status.Disputed) locked += m.amount;
        }
        assertEq(tok.balanceOf(address(esc)), locked);
        assertEq(tok.balanceOf(client) + tok.balanceOf(payee) + tok.balanceOf(address(esc)), 10_000e6);
    }

    function testFuzz_resolveSplitSumsToAmount(uint128 amount, uint256 toPayee) public {
        amount = uint128(bound(amount, 1, 1e12));
        toPayee = bound(toPayee, 0, amount);
        delete amts;
        delete dls;
        amts.push(amount);
        dls.push(uint64(block.timestamp + 1 days));
        vm.startPrank(client);
        tok.faucet(10_000e6);
        uint256 id = esc.createJob(payee, arb, address(tok), amts, dls);
        // amount may exceed balance; top up via repeated faucet is bounded, so cap
        vm.stopPrank();
        if (amount > tok.balanceOf(client)) return;
        vm.prank(client);
        esc.fund(id);
        vm.prank(client);
        esc.dispute(id, 0);
        vm.prank(arb);
        esc.resolve(id, 0, toPayee);
        assertEq(tok.balanceOf(payee), toPayee);
        assertEq(tok.balanceOf(address(esc)), 0);
    }

    // ------------------------------------------------ token sanity (11-22)

    function test_createRejectsTokenWithoutCode() public {
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.BadParams.selector);
        esc.createJob(payee, arb, address(0x1234), amts, dls);
    }

    function test_fundRejectsFeeOnTransferToken() public {
        FeeToken fee = new FeeToken();
        vm.startPrank(client);
        fee.mint(client, 10_000e6);
        fee.approve(address(esc), type(uint256).max);
        uint256 id = esc.createJob(payee, arb, address(fee), amts, dls);
        vm.expectRevert(MilestoneEscrow.TransferFailed.selector);
        esc.fund(id);
        vm.stopPrank();
        // nothing moved, job still unfunded
        assertEq(fee.balanceOf(address(esc)), 0);
        assertFalse(esc.getJob(id).funded);
    }

    function test_feeTokenCannotDrainOtherJobs() public {
        // an honest job on the real token keeps its full balance
        uint256 honest = _createFunded();
        FeeToken fee = new FeeToken();
        vm.startPrank(client);
        fee.mint(client, 10_000e6);
        fee.approve(address(esc), type(uint256).max);
        uint256 id = esc.createJob(payee, arb, address(fee), amts, dls);
        vm.expectRevert(MilestoneEscrow.TransferFailed.selector);
        esc.fund(id);
        vm.stopPrank();
        assertEq(tok.balanceOf(address(esc)), 600e6);
        assertTrue(esc.getJob(honest).funded);
    }
}

/// @dev Takes a 1% fee on every transfer (the recipient gets 99%).
contract FeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external { balanceOf[to] += v; }

    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }

    function transfer(address to, uint256 v) external returns (bool) { _move(msg.sender, to, v); return true; }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        _move(f, to, v);
        return true;
    }

    function _move(address f, address to, uint256 v) internal {
        balanceOf[f] -= v;
        balanceOf[to] += v - v / 100;
    }
}
