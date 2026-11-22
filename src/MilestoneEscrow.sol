// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title MilestoneEscrow
/// @notice Milestone-based escrow for any ERC-20 (built for USDG). A client funds a job,
///         approves milestones to pay the payee, reclaims unapproved milestones after their
///         deadline, and either side can escalate a milestone to a neutral arbiter.
contract MilestoneEscrow {
    enum Status { Pending, Released, Refunded, Disputed, Resolved }

    struct Milestone {
        uint128 amount;
        uint64 deadline;
        Status status;
    }

    struct Job {
        address client;
        address payee;
        address arbiter;
        address token;
        bool funded;
        bool cancelled;
        uint256 total;
    }

    uint256 public nextJobId;
    mapping(uint256 => Job) internal _jobs;
    mapping(uint256 => Milestone[]) internal _milestones;

    uint256 private _lock = 1;

    event JobCreated(uint256 indexed id, address indexed client, address indexed payee, address arbiter, address token, uint256 total);
    event JobFunded(uint256 indexed id, uint256 total);
    event JobCancelled(uint256 indexed id);
    event MilestoneReleased(uint256 indexed id, uint256 indexed index, uint256 amount);
    event MilestoneRefunded(uint256 indexed id, uint256 indexed index, uint256 amount);
    event MilestoneDisputed(uint256 indexed id, uint256 indexed index, address by);
    event MilestoneResolved(uint256 indexed id, uint256 indexed index, uint256 toPayee, uint256 toClient);

    error BadParams();
    error NotClient();
    error NotArbiter();
    error NotParty();
    error NotFunded();
    error AlreadyFunded();
    error Cancelled();
    error WrongStatus();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ---------------------------------------------------------------- views

    function getJob(uint256 id) external view returns (Job memory) {
        return _jobs[id];
    }

    function milestoneCount(uint256 id) external view returns (uint256) {
        return _milestones[id].length;
    }

    function getMilestone(uint256 id, uint256 index) external view returns (Milestone memory) {
        return _milestones[id][index];
    }

    function getMilestones(uint256 id) external view returns (Milestone[] memory) {
        return _milestones[id];
    }

    // ------------------------------------------------------------- lifecycle

    /// @notice Create a job. No funds move yet; the client calls `fund` next.
    function createJob(
        address payee,
        address arbiter,
        address token,
        uint128[] calldata amounts,
        uint64[] calldata deadlines
    ) external returns (uint256 id) {
        uint256 n = amounts.length;
        if (n == 0 || n > 50 || n != deadlines.length) revert BadParams();
        if (payee == address(0) || arbiter == address(0) || token == address(0)) revert BadParams();
        // A call to an address without code "succeeds" with empty return data, so a job on such a
        // token would look funded while holding nothing. Reject it up front.
        if (token.code.length == 0) revert BadParams();
        if (payee == msg.sender || arbiter == msg.sender || arbiter == payee) revert BadParams();

        id = nextJobId++;
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0 || deadlines[i] <= block.timestamp) revert BadParams();
            total += amounts[i];
            _milestones[id].push(Milestone(amounts[i], deadlines[i], Status.Pending));
        }
        _jobs[id] = Job(msg.sender, payee, arbiter, token, false, false, total);
        emit JobCreated(id, msg.sender, payee, arbiter, token, total);
    }

    /// @notice Client deposits the full amount (requires prior ERC-20 approval).
    function fund(uint256 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (msg.sender != j.client) revert NotClient();
        if (j.funded) revert AlreadyFunded();
        if (j.cancelled) revert Cancelled();
        j.funded = true;
        // Balances of all jobs on the same token share this contract's account, so a
        // fee-on-transfer or rebasing-down token that delivers less than `total` would let this
        // job's payouts draw on other jobs' deposits. Require the full amount to arrive.
        uint256 before = IERC20(j.token).balanceOf(address(this));
        _pull(j.token, msg.sender, j.total);
        if (IERC20(j.token).balanceOf(address(this)) - before < j.total) revert TransferFailed();
        emit JobFunded(id, j.total);
    }

    /// @notice Client cancels a job that has not been funded.
    function cancel(uint256 id) external {
        Job storage j = _jobs[id];
        if (msg.sender != j.client) revert NotClient();
        if (j.funded) revert AlreadyFunded();
        j.cancelled = true;
        emit JobCancelled(id);
    }

    /// @notice Client approves a milestone and pays the payee.
    function approve(uint256 id, uint256 index) external nonReentrant {
        Job storage j = _jobs[id];
        if (msg.sender != j.client) revert NotClient();
        Milestone storage m = _open(id, j, index);
        if (m.status != Status.Pending) revert WrongStatus();
        m.status = Status.Released;
        _push(j.token, j.payee, m.amount);
        emit MilestoneReleased(id, index, m.amount);
    }

    /// @notice Client reclaims a milestone once its deadline has passed without approval or dispute.
    function refund(uint256 id, uint256 index) external nonReentrant {
        Job storage j = _jobs[id];
        if (msg.sender != j.client) revert NotClient();
        Milestone storage m = _open(id, j, index);
        if (m.status != Status.Pending) revert WrongStatus();
        if (block.timestamp <= m.deadline) revert DeadlineNotPassed();
        m.status = Status.Refunded;
        _push(j.token, j.client, m.amount);
        emit MilestoneRefunded(id, index, m.amount);
    }

    /// @notice Client or payee escalates a pending milestone to the arbiter.
    ///         Once disputed, only the arbiter can settle it (so a payee can freeze a refund by
    ///         disputing before the client refunds; the arbiter then decides).
    function dispute(uint256 id, uint256 index) external {
        Job storage j = _jobs[id];
        if (msg.sender != j.client && msg.sender != j.payee) revert NotParty();
        Milestone storage m = _open(id, j, index);
        if (m.status != Status.Pending) revert WrongStatus();
        m.status = Status.Disputed;
        emit MilestoneDisputed(id, index, msg.sender);
    }

    /// @notice Arbiter splits a disputed milestone. `toPayee` goes to the payee, the rest to the client.
    function resolve(uint256 id, uint256 index, uint256 toPayee) external nonReentrant {
        Job storage j = _jobs[id];
        if (msg.sender != j.arbiter) revert NotArbiter();
        Milestone storage m = _open(id, j, index);
        if (m.status != Status.Disputed) revert WrongStatus();
        if (toPayee > m.amount) revert BadParams();
        m.status = Status.Resolved;
        uint256 toClient = m.amount - toPayee;
        if (toPayee > 0) _push(j.token, j.payee, toPayee);
        if (toClient > 0) _push(j.token, j.client, toClient);
        emit MilestoneResolved(id, index, toPayee, toClient);
    }

    // -------------------------------------------------------------- internals

    function _open(uint256 id, Job storage j, uint256 index) internal view returns (Milestone storage m) {
        if (j.client == address(0)) revert BadParams();
        if (!j.funded) revert NotFunded();
        if (index >= _milestones[id].length) revert BadParams();
        m = _milestones[id][index];
    }

    function _pull(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _push(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
