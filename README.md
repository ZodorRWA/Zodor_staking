Added ZodorStaking contract with multi-plan staking, rewards, and refund mode

* Implemented staking contract with 4 predefined plans (duration + reward basis points).
* Supports secure staking, claiming, and reward distribution using SafeERC20.
* Integrated reward pool management with `depositRewards` and `withdrawReward`.
* Added refund mode allowing proportional rewards if staking is cut short.
* Tracks global stats (total staked, users, positions) and per-user positions.
* Includes pausable and ownable access control with ReentrancyGuard protection.
* Provides helper views for pending rewards, plans, stats, and user positions.
* Security: disallows direct ETH transfers and invalid function calls.
