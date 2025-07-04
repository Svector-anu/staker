// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@thirdweb-dev/contracts/extension/Ownable.sol";

contract StakingContract is Ownable {
    using SafeMath for uint256;

    IERC20 public stakingToken;
    IERC20 public rewardToken;

    address public treasury;

    uint256 public rewardRate;
    uint256 public lockPeriod;
    uint256 public penaltyRate;

    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public lastUpdateTime;

    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastStakeTime;
    }

    mapping(address => StakeInfo) public stakes;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 penalty);
    event RewardClaimed(address indexed user, uint256 amount);

    constructor(
        address _stakingToken,
        address _rewardToken,
        address _treasury,
        uint256 _rewardRate,
        uint256 _lockPeriod,
        uint256 _penaltyRate
    ) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        treasury = _treasury;
        rewardRate = _rewardRate;
        lockPeriod = _lockPeriod;
        penaltyRate = _penaltyRate;
        lastUpdateTime = block.timestamp;
    }

    function _canSetOwner() internal view override returns (bool) {
        return msg.sender == owner();
    }

    modifier updatePool() {
        if (totalStaked > 0) {
            uint256 duration = block.timestamp.sub(lastUpdateTime);
            uint256 reward = duration.mul(rewardRate);
            accRewardPerShare = accRewardPerShare.add(reward.mul(1e18).div(totalStaked));
        }
        lastUpdateTime = block.timestamp;
        _;
    }

    function stake(uint256 _amount) external updatePool {
        require(_amount > 0, "Cannot stake 0");
        StakeInfo storage user = stakes[msg.sender];

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(accRewardPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                rewardToken.transfer(msg.sender, pending);
                emit RewardClaimed(msg.sender, pending);
            }
        }

        stakingToken.transferFrom(msg.sender, address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(accRewardPerShare).div(1e18);
        user.lastStakeTime = block.timestamp;
        totalStaked = totalStaked.add(_amount);

        emit Staked(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external updatePool {
        StakeInfo storage user = stakes[msg.sender];
        require(user.amount >= _amount, "Insufficient stake");

        uint256 pending = user.amount.mul(accRewardPerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            rewardToken.transfer(msg.sender, pending);
            emit RewardClaimed(msg.sender, pending);
        }

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(accRewardPerShare).div(1e18);
        totalStaked = totalStaked.sub(_amount);

        uint256 penalty = 0;
        if (block.timestamp < user.lastStakeTime + lockPeriod) {
            penalty = _amount.mul(penaltyRate).div(100);
            stakingToken.transfer(treasury, penalty);
        }

        stakingToken.transfer(msg.sender, _amount.sub(penalty));
        emit Withdrawn(msg.sender, _amount, penalty);
    }

    function pendingRewards(address _user) external view returns (uint256) {
        StakeInfo memory user = stakes[_user];
        uint256 tempAccReward = accRewardPerShare;

        if (totalStaked > 0) {
            uint256 duration = block.timestamp.sub(lastUpdateTime);
            uint256 reward = duration.mul(rewardRate);
            tempAccReward = tempAccReward.add(reward.mul(1e18).div(totalStaked));
        }

        return user.amount.mul(tempAccReward).div(1e18).sub(user.rewardDebt);
    }

    // Admin functions
    function setRewardRate(uint256 _rate) external onlyOwner {
        rewardRate = _rate;
    }

    function setLockPeriod(uint256 _period) external onlyOwner {
        lockPeriod = _period;
    }

    function setPenaltyRate(uint256 _rate) external onlyOwner {
        penaltyRate = _rate;
    }

    function setTreasury(address _addr) external onlyOwner {
        treasury = _addr;
    }

    // View user stake
    function getUserInfo(address _user) external view returns (StakeInfo memory) {
        return stakes[_user];
    }

    function getConfig()
        external
        view
        returns (address, address, address, uint256, uint256, uint256)
    {
        return (
            address(stakingToken),
            address(rewardToken),
            treasury,
            rewardRate,
            lockPeriod,
            penaltyRate
        );
    }
}
