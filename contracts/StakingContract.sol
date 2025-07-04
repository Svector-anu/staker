// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title AdvancedStakingRewards
 * @dev A comprehensive staking contract with multiple reward mechanisms
 * Features:
 * - Stake ERC-20 tokens to earn rewards
 * - Multiple reward pools with different APY rates
 * - Time-based reward calculation
 * - Early withdrawal penalties
 * - Compound staking
 * - Emergency functions
 */
contract AdvancedStakingRewards is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Structs
    struct StakeInfo {
        uint256 amount;           // Amount staked
        uint256 rewardDebt;       // Reward debt for accurate reward calculation
        uint256 lastStakeTime;    // Timestamp of last stake
        uint256 totalRewardsClaimed; // Total rewards claimed by user
        uint256 lockEndTime;      // End time for locked staking (0 if no lock)
    }

    struct PoolInfo {
        IERC20 stakingToken;      // Token to be staked
        IERC20 rewardToken;       // Token given as reward
        uint256 rewardPerSecond;  // Reward tokens per second
        uint256 lastRewardTime;   // Last time rewards were calculated
        uint256 accRewardPerShare; // Accumulated rewards per share
        uint256 totalStaked;      // Total tokens staked in this pool
        uint256 minStakeAmount;   // Minimum stake amount
        uint256 lockDuration;     // Lock duration in seconds (0 for no lock)
        uint256 earlyWithdrawPenalty; // Penalty percentage (basis points)
        bool isActive;            // Whether pool is active
    }

    // State variables
    mapping(uint256 => PoolInfo) public poolInfo;
    mapping(uint256 => mapping(address => StakeInfo)) public userInfo;
    mapping(address => bool) public authorizedOperators;
    
    uint256 public poolLength;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_PENALTY = 5000; // 50% max penalty
    uint256 public emergencyWithdrawCooldown = 24 hours;
    
    address public treasuryAddress;
    bool public emergencyWithdrawEnabled;

    // Events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardClaimed(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 indexed pid, address stakingToken, address rewardToken);
    event PoolUpdated(uint256 indexed pid, uint256 rewardPerSecond);
    event PenaltyPaid(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(address _initialOwner, address _treasuryAddress) Ownable(_initialOwner) {
        require(_initialOwner != address(0), "Invalid owner address");
        require(_treasuryAddress != address(0), "Invalid treasury address");
        treasuryAddress = _treasuryAddress;
    }

    // Modifiers
    modifier validPool(uint256 _pid) {
        require(_pid < poolLength, "Invalid pool ID");
        require(poolInfo[_pid].isActive, "Pool is not active");
        _;
    }

    modifier onlyOperator() {
        require(authorizedOperators[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }

    /**
     * @dev Add a new staking pool
     * @param _stakingToken Token to be staked
     * @param _rewardToken Token given as reward
     * @param _rewardPerSecond Reward tokens per second
     * @param _minStakeAmount Minimum stake amount
     * @param _lockDuration Lock duration in seconds (0 for no lock)
     * @param _earlyWithdrawPenalty Penalty percentage in basis points
     */
    function addPool(
        IERC20 _stakingToken,
        IERC20 _rewardToken,
        uint256 _rewardPerSecond,
        uint256 _minStakeAmount,
        uint256 _lockDuration,
        uint256 _earlyWithdrawPenalty
    ) external onlyOwner {
        require(address(_stakingToken) != address(0), "Invalid staking token");
        require(address(_rewardToken) != address(0), "Invalid reward token");
        require(_earlyWithdrawPenalty <= MAX_PENALTY, "Penalty too high");

        poolInfo[poolLength] = PoolInfo({
            stakingToken: _stakingToken,
            rewardToken: _rewardToken,
            rewardPerSecond: _rewardPerSecond,
            lastRewardTime: block.timestamp,
            accRewardPerShare: 0,
            totalStaked: 0,
            minStakeAmount: _minStakeAmount,
            lockDuration: _lockDuration,
            earlyWithdrawPenalty: _earlyWithdrawPenalty,
            isActive: true
        });

        emit PoolAdded(poolLength, address(_stakingToken), address(_rewardToken));
        poolLength++;
    }

    /**
     * @dev Update pool reward rate
     * @param _pid Pool ID
     * @param _rewardPerSecond New reward rate
     */
    function updatePool(uint256 _pid, uint256 _rewardPerSecond) external onlyOperator validPool(_pid) {
        _updatePoolRewards(_pid);
        poolInfo[_pid].rewardPerSecond = _rewardPerSecond;
        emit PoolUpdated(_pid, _rewardPerSecond);
    }

    /**
     * @dev Stake tokens in a pool
     * @param _pid Pool ID
     * @param _amount Amount to stake
     */
    function stake(uint256 _pid, uint256 _amount) external nonReentrant whenNotPaused validPool(_pid) {
        require(_amount > 0, "Cannot stake 0 tokens");
        
        PoolInfo storage pool = poolInfo[_pid];
        StakeInfo storage user = userInfo[_pid][msg.sender];
        
        require(_amount >= pool.minStakeAmount, "Below minimum stake amount");

        // Update pool rewards
        _updatePoolRewards(_pid);

        // If user has existing stake, claim pending rewards
        if (user.amount > 0) {
            uint256 pending = _calculatePendingRewards(_pid, msg.sender);
            if (pending > 0) {
                _safeRewardTransfer(_pid, msg.sender, pending);
                user.totalRewardsClaimed += pending;
                emit RewardClaimed(msg.sender, _pid, pending);
            }
        }

        // Transfer tokens from user
        pool.stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Update user info
        user.amount += _amount;
        user.lastStakeTime = block.timestamp;
        if (pool.lockDuration > 0) {
            user.lockEndTime = block.timestamp + pool.lockDuration;
        }
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION;

        // Update pool info
        pool.totalStaked += _amount;

        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
     * @dev Withdraw staked tokens and claim rewards
     * @param _pid Pool ID
     * @param _amount Amount to withdraw
     */
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant validPool(_pid) {
        require(_amount > 0, "Cannot withdraw 0 tokens");
        
        PoolInfo storage pool = poolInfo[_pid];
        StakeInfo storage user = userInfo[_pid][msg.sender];
        
        require(user.amount >= _amount, "Insufficient staked amount");

        // Update pool rewards
        _updatePoolRewards(_pid);

        // Calculate and send pending rewards
        uint256 pending = _calculatePendingRewards(_pid, msg.sender);
        if (pending > 0) {
            _safeRewardTransfer(_pid, msg.sender, pending);
            user.totalRewardsClaimed += pending;
            emit RewardClaimed(msg.sender, _pid, pending);
        }

        // Check if withdrawal is before lock period and apply penalty
        uint256 withdrawAmount = _amount;
        if (user.lockEndTime > block.timestamp && pool.earlyWithdrawPenalty > 0) {
            uint256 penalty = (_amount * pool.earlyWithdrawPenalty) / 10000;
            withdrawAmount = _amount - penalty;
            
            // Send penalty to treasury
            if (penalty > 0) {
                pool.stakingToken.safeTransfer(treasuryAddress, penalty);
                emit PenaltyPaid(msg.sender, _pid, penalty);
            }
        }

        // Update user info
        user.amount -= _amount;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION;

        // Update pool info
        pool.totalStaked -= _amount;

        // Transfer tokens to user
        pool.stakingToken.safeTransfer(msg.sender, withdrawAmount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    /**
     * @dev Claim rewards without withdrawing staked tokens
     * @param _pid Pool ID
     */
    function claimRewards(uint256 _pid) external nonReentrant whenNotPaused validPool(_pid) {
        StakeInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount > 0, "No tokens staked");

        // Update pool rewards
        _updatePoolRewards(_pid);

        uint256 pending = _calculatePendingRewards(_pid, msg.sender);
        require(pending > 0, "No rewards to claim");

        // Update user reward debt
        user.rewardDebt = (user.amount * poolInfo[_pid].accRewardPerShare) / PRECISION;
        user.totalRewardsClaimed += pending;

        // Transfer rewards
        _safeRewardTransfer(_pid, msg.sender, pending);

        emit RewardClaimed(msg.sender, _pid, pending);
    }

    /**
     * @dev Compound rewards by automatically staking them (if staking and reward tokens are same)
     * @param _pid Pool ID
     */
    function compound(uint256 _pid) external nonReentrant whenNotPaused validPool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        StakeInfo storage user = userInfo[_pid][msg.sender];
        
        require(user.amount > 0, "No tokens staked");
        require(address(pool.stakingToken) == address(pool.rewardToken), "Cannot compound different tokens");

        // Update pool rewards
        _updatePoolRewards(_pid);

        uint256 pending = _calculatePendingRewards(_pid, msg.sender);
        require(pending > 0, "No rewards to compound");

        // Add rewards to staked amount
        user.amount += pending;
        user.totalRewardsClaimed += pending;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / PRECISION;

        // Update pool total
        pool.totalStaked += pending;

        emit Deposit(msg.sender, _pid, pending);
        emit RewardClaimed(msg.sender, _pid, pending);
    }

    /**
     * @dev Emergency withdraw without caring about rewards
     * @param _pid Pool ID
     */
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        require(emergencyWithdrawEnabled || msg.sender == owner(), "Emergency withdraw disabled");
        
        PoolInfo storage pool = poolInfo[_pid];
        StakeInfo storage user = userInfo[_pid][msg.sender];
        
        require(user.amount > 0, "No tokens staked");

        uint256 amount = user.amount;
        
        // Reset user info
        user.amount = 0;
        user.rewardDebt = 0;
        user.lockEndTime = 0;

        // Update pool total
        pool.totalStaked -= amount;

        // Transfer tokens (may apply penalty)
        uint256 withdrawAmount = amount;
        if (pool.earlyWithdrawPenalty > 0 && user.lockEndTime > block.timestamp) {
            uint256 penalty = (amount * pool.earlyWithdrawPenalty) / 10000;
            withdrawAmount = amount - penalty;
            
            if (penalty > 0) {
                pool.stakingToken.safeTransfer(treasuryAddress, penalty);
                emit PenaltyPaid(msg.sender, _pid, penalty);
            }
        }

        pool.stakingToken.safeTransfer(msg.sender, withdrawAmount);

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    /**
     * @dev Update reward variables for a pool
     * @param _pid Pool ID
     */
    function _updatePoolRewards(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }

        if (pool.totalStaked == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 multiplier = block.timestamp - pool.lastRewardTime;
        uint256 reward = multiplier * pool.rewardPerSecond;
        
        pool.accRewardPerShare += (reward * PRECISION) / pool.totalStaked;
        pool.lastRewardTime = block.timestamp;
    }

    /**
     * @dev Calculate pending rewards for a user
     * @param _pid Pool ID
     * @param _user User address
     * @return Pending reward amount
     */
    function _calculatePendingRewards(uint256 _pid, address _user) internal view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        StakeInfo storage user = userInfo[_pid][_user];
        
        uint256 accRewardPerShare = pool.accRewardPerShare;
        
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked != 0) {
            uint256 multiplier = block.timestamp - pool.lastRewardTime;
            uint256 reward = multiplier * pool.rewardPerSecond;
            accRewardPerShare += (reward * PRECISION) / pool.totalStaked;
        }
        
        return ((user.amount * accRewardPerShare) / PRECISION) - user.rewardDebt;
    }

    /**
     * @dev Safe reward transfer function
     * @param _pid Pool ID
     * @param _to Recipient address
     * @param _amount Amount to transfer
     */
    function _safeRewardTransfer(uint256 _pid, address _to, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 balance = pool.rewardToken.balanceOf(address(this));
        
        if (_amount > balance) {
            pool.rewardToken.safeTransfer(_to, balance);
        } else {
            pool.rewardToken.safeTransfer(_to, _amount);
        }
    }

    // View functions
    
    /**
     * @dev Get pending rewards for a user
     * @param _pid Pool ID
     * @param _user User address
     * @return Pending reward amount
     */
    function pendingRewards(uint256 _pid, address _user) external view returns (uint256) {
        return _calculatePendingRewards(_pid, _user);
    }

    /**
     * @dev Get user staking info
     * @param _pid Pool ID
     * @param _user User address
     * @return amount staked, rewards claimed, lock end time, pending rewards
     */
    function getUserInfo(uint256 _pid, address _user) external view returns (
        uint256 amount,
        uint256 totalRewardsClaimed,
        uint256 lockEndTime,
        uint256 pendingRewards_
    ) {
        StakeInfo storage user = userInfo[_pid][_user];
        return (
            user.amount,
            user.totalRewardsClaimed,
            user.lockEndTime,
            _calculatePendingRewards(_pid, _user)
        );
    }

    /**
     * @dev Get pool information
     * @param _pid Pool ID
     * @return Pool details
     */
    function getPoolInfo(uint256 _pid) external view returns (
        address stakingToken,
        address rewardToken,
        uint256 rewardPerSecond,
        uint256 totalStaked,
        uint256 minStakeAmount,
        uint256 lockDuration,
        uint256 earlyWithdrawPenalty,
        bool isActive
    ) {
        PoolInfo storage pool = poolInfo[_pid];
        return (
            address(pool.stakingToken),
            address(pool.rewardToken),
            pool.rewardPerSecond,
            pool.totalStaked,
            pool.minStakeAmount,
            pool.lockDuration,
            pool.earlyWithdrawPenalty,
            pool.isActive
        );
    }

    /**
     * @dev Calculate APY for a pool
     * @param _pid Pool ID
     * @return APY in basis points (10000 = 100%)
     */
    function calculateAPY(uint256 _pid) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.totalStaked == 0) return 0;
        
        uint256 yearlyRewards = pool.rewardPerSecond * 365 days;
        return (yearlyRewards * 10000) / pool.totalStaked;
    }

    // Admin functions

    /**
     * @dev Set authorized operator
     * @param _operator Operator address
     * @param _authorized Whether authorized
     */
    function setOperator(address _operator, bool _authorized) external onlyOwner {
        authorizedOperators[_operator] = _authorized;
    }

    /**
     * @dev Update pool status
     * @param _pid Pool ID
     * @param _isActive Whether pool is active
     */
    function setPoolStatus(uint256 _pid, bool _isActive) external onlyOwner {
        require(_pid < poolLength, "Invalid pool ID");
        poolInfo[_pid].isActive = _isActive;
    }

    /**
     * @dev Update treasury address
     * @param _treasuryAddress New treasury address
     */
    function setTreasuryAddress(address _treasuryAddress) external onlyOwner {
        require(_treasuryAddress != address(0), "Invalid treasury address");
        treasuryAddress = _treasuryAddress;
    }

    /**
     * @dev Enable/disable emergency withdraw
     * @param _enabled Whether emergency withdraw is enabled
     */
    function setEmergencyWithdraw(bool _enabled) external onlyOwner {
        emergencyWithdrawEnabled = _enabled;
    }

    /**
     * @dev Pause/unpause contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency function to withdraw stuck tokens
     * @param _token Token address
     * @param _amount Amount to withdraw
     * @param _to Recipient address
     */
    function emergencyTokenWithdraw(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOwner {
        require(_to != address(0), "Invalid recipient");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    /**
     * @dev Deposit reward tokens to contract
     * @param _pid Pool ID
     * @param _amount Amount to deposit
     */
    function depositRewards(uint256 _pid, uint256 _amount) external validPool(_pid) {
        require(_amount > 0, "Cannot deposit 0 tokens");
        PoolInfo storage pool = poolInfo[_pid];
        pool.rewardToken.safeTransferFrom(msg.sender, address(this), _amount);
    }
}