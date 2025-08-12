// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract ZodorStaking is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable zodToken;

    struct Plan {
        uint256 durationMinutes;
        uint256 rewardBasisPoints;
    }

    struct Position {
        uint256 amount;
        uint64 startTimestamp;
        uint8 planId;
        bool claimed;
    }

    Plan[4] public plans;

    mapping(address => Position[]) public userPositions;
    mapping(address => bool) public hasStakedBefore;

    uint256 public totalStaked;
    uint256 public rewardPool;
    uint256 public totalUsers;
    uint256 public totalPositions;

    bool public refundMode;
    uint256 public refundActivationTime;

    event StakeCreated(
        address indexed user,
        uint256 amount,
        uint8 planId,
        uint256 index
    );
    event StakeClaimed(
        address indexed user,
        uint256 index,
        uint256 principal,
        uint256 reward
    );
    event RewardDeposit(uint256 amount);
    event RewardWithdraw(uint256 amount);
    event RefundActivated(uint256 activationTime);

    constructor(address _zodToken, address initialOwner) Ownable(initialOwner) {
        require(_zodToken != address(0), "Invalid token address");
        require(initialOwner != address(0), "Invalid owner address");

        zodToken = IERC20(_zodToken);
        plans[0] = Plan(1, 1000);
        plans[1] = Plan(2, 3000);
        plans[2] = Plan(5, 7000);
        plans[3] = Plan(10, 10000);
    }

    function stake(uint8 planId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        require(!refundMode, "Staking disabled in refund mode");
        require(planId < plans.length, "Invalid plan ID");
        require(amount != 0, "Amount must be greater than zero");

        Plan storage plan = plans[planId];
        uint256 projectedReward = calculateReward(
            amount,
            plan.rewardBasisPoints
        );
        require(rewardPool >= projectedReward, "Insufficient reward pool");

        if (!hasStakedBefore[msg.sender]) {
            hasStakedBefore[msg.sender] = true;
            unchecked {
                ++totalUsers;
            }
        }

        unchecked {
            ++totalPositions;
        }

        userPositions[msg.sender].push(
            Position({
                amount: amount,
                startTimestamp: uint64(block.timestamp),
                planId: planId,
                claimed: false
            })
        );

        unchecked {
            totalStaked += amount;
            rewardPool -= projectedReward;
        }

        zodToken.safeTransferFrom(msg.sender, address(this), amount);

        emit StakeCreated(
            msg.sender,
            amount,
            planId,
            userPositions[msg.sender].length - 1
        );
    }

    function claim(uint256 index) external nonReentrant whenNotPaused {
        require(index < userPositions[msg.sender].length, "Invalid index");
        Position storage pos = userPositions[msg.sender][index];
        require(!pos.claimed, "Already claimed");
        require(pos.amount != 0, "Invalid position");

        Plan storage plan = plans[pos.planId];
        uint256 fullReward = calculateReward(
            pos.amount,
            plan.rewardBasisPoints
        );
        uint256 reward;

        if (refundMode) {
            require(
                refundActivationTime > pos.startTimestamp,
                "Refund before stake"
            );

            uint256 durationSeconds = plan.durationMinutes * 60;
            require(durationSeconds > 0, "Invalid plan duration");

            uint256 start = uint256(pos.startTimestamp);
            uint256 end = start + durationSeconds;

            uint256 elapsedSeconds;
            if (block.timestamp >= end) {
                elapsedSeconds = durationSeconds;
            } else {
                elapsedSeconds = block.timestamp > start
                    ? block.timestamp - start
                    : 0;
            }

            reward = (fullReward * elapsedSeconds) / durationSeconds;

            if (fullReward > reward) {
                uint256 unusedReward = fullReward - reward;
                unchecked {
                    rewardPool += unusedReward;
                }
            }
        } else {
            require(
                block.timestamp >=
                    pos.startTimestamp + plan.durationMinutes * 60,
                "Lock period not ended"
            );
            reward = fullReward;
        }

        pos.claimed = true;
        unchecked {
            totalStaked -= pos.amount;
        }

        uint256 totalToTransfer = pos.amount + reward;
        zodToken.safeTransfer(msg.sender, totalToTransfer);

        emit StakeClaimed(msg.sender, index, pos.amount, reward);
    }

    function depositRewards(uint256 amount) external onlyOwner nonReentrant {
        require(amount != 0, "Zero amount");
        zodToken.safeTransferFrom(msg.sender, address(this), amount);
        unchecked {
            rewardPool += amount;
        }
        emit RewardDeposit(amount);
    }

    function withdrawReward(uint256 amount) external onlyOwner nonReentrant {
        require(amount != 0, "Amount must be greater than zero");
        require(amount <= rewardPool, "Insufficient reward pool");
        unchecked {
            rewardPool -= amount;
        }
        zodToken.safeTransfer(msg.sender, amount);
        emit RewardWithdraw(amount);
    }

    function activateRefund() external onlyOwner {
        require(!refundMode, "Already in refund mode");
        refundMode = true;
        refundActivationTime = block.timestamp;
        emit RefundActivated(block.timestamp);
    }

    function calculateReward(uint256 amount, uint256 rewardBasisPoints)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount, rewardBasisPoints, 10000);
    }

    function pendingReward(address user, uint256 index)
        external
        view
        returns (uint256)
    {
        require(index < userPositions[user].length, "Invalid index");
        Position memory pos = userPositions[user][index];
        if (pos.claimed || pos.amount == 0) return 0;

        Plan storage plan = plans[pos.planId];
        uint256 fullReward = calculateReward(
            pos.amount,
            plan.rewardBasisPoints
        );

        if (refundMode) {
            if (refundActivationTime <= pos.startTimestamp) return 0;

            uint256 durationSeconds = plan.durationMinutes * 60;
            if (durationSeconds == 0) return 0;

            uint256 start = uint256(pos.startTimestamp);
            uint256 end = start + durationSeconds;

            uint256 elapsedSeconds;
            if (block.timestamp >= end) {
                elapsedSeconds = durationSeconds;
            } else {
                elapsedSeconds = block.timestamp > start
                    ? block.timestamp - start
                    : 0;
            }

            return (fullReward * elapsedSeconds) / durationSeconds;
        } else {
            if (
                block.timestamp < pos.startTimestamp + plan.durationMinutes * 60
            ) return 0;
            return fullReward;
        }
    }

    function getAllPlans() external view returns (Plan[4] memory) {
        return plans;
    }

    function getStats()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (totalStaked, rewardPool, totalUsers, totalPositions);
    }

    function getUserPositions(address user)
        external
        view
        returns (Position[] memory)
    {
        return userPositions[user];
    }

    function pause() external onlyOwner {
        _pause();
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit Unpaused(msg.sender);
    }

    receive() external payable {
        revert("Direct transfer not allowed");
    }

    fallback() external {
        revert("Function not found");
    }
}
