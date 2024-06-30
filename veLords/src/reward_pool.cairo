// veYFI's RewardPool & dYFIRewardPool contract ported to Cairo
// it's a generalization of both contracts suitable for
// veLORDS and dLORDS

#[starknet::contract]
mod reward_pool {
    use core::cmp::max;
    use core::integer::BoundedInt;
    use core::num::traits::Zero;
    use lordship::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use lordship::interfaces::IRewardPool::IRewardPool;
    use lordship::interfaces::IVE::{IVEDispatcher, IVEDispatcherTrait};
    use lordship::velords::Point;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use starknet::{ClassHash, ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

    const DAY: u64 = 3600 * 24;
    const WEEK: u64 = DAY * 7;
    const TOKEN_CHECKPOINT_DEADLINE: u64 = DAY;
    const ITERATION_LIMIT: u32 = 200;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        // component storage
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        velords: IVEDispatcher,
        reward_token: IERC20Dispatcher,
        // Epoch time when fee distribution starts
        start_time: u64,
        // Epoch when the last token checkpoint was made
        time_cursor: u64,
        // Mapping between addresses and their last token checkpoint epoch
        time_cursor_of: LegacyMap<ContractAddress, u64>,
        // Timestamp when the last checkpoint was made
        last_token_time: u64,
        // Mapping between epoch and the total number of tokens distributed in that week
        tokens_per_week: LegacyMap<u64, u256>,
        token_last_balance: u256,
        // Mapping between epoch and the total veLORDS supply at that epoch
        // epoch -> veLORDS supply
        ve_supply: LegacyMap<u64, u256>
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        CheckpointToken: CheckpointToken,
        Claimed: Claimed,
        RewardReceived: RewardReceived
    }

    #[derive(Drop, starknet::Event)]
    pub struct CheckpointToken {
        time: u64,
        tokens: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct Claimed {
        #[key]
        pub recipient: ContractAddress,
        amount: u256,
        claim_epoch: u64,
        max_epoch: u64
    }

    #[derive(Drop, starknet::Event)]
    pub struct RewardReceived {
        #[key]
        pub sender: ContractAddress,
        amount: u256
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        velords: ContractAddress,
        reward_token: ContractAddress,
        start_time: u64
    ) {
        self.ownable.initializer(owner);

        self.velords.write(IVEDispatcher { contract_address: velords });
        self.reward_token.write(IERC20Dispatcher { contract_address: reward_token });

        let t: u64 = floor_to_week(start_time);
        self.start_time.write(t);
        self.last_token_time.write(t);
        self.time_cursor.write(t);
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable._upgrade(new_class_hash);
        }
    }

    #[abi(embed_v0)]
    impl IRewardPoolImpl of IRewardPool<ContractState> {
        fn get_reward_token(self: @ContractState) -> ContractAddress {
            self.reward_token.read().contract_address
        }

        fn get_start_time(self: @ContractState) -> u64 {
            self.start_time.read()
        }

        fn get_time_cursor(self: @ContractState) -> u64 {
            self.time_cursor.read()
        }

        fn get_time_cursor_of(self: @ContractState, account: ContractAddress) -> u64 {
            self.time_cursor_of.read(account)
        }

        fn get_last_token_time(self: @ContractState) -> u64 {
            self.last_token_time.read()
        }

        fn get_tokens_per_week(self: @ContractState, week: u64) -> u256 {
            self.tokens_per_week.read(week)
        }

        fn get_token_last_balance(self: @ContractState) -> u256 {
            self.token_last_balance.read()
        }

        fn get_ve_supply(self: @ContractState, week: u64) -> u256 {
            self.ve_supply.read(week)
        }

        /// Receive reward token into the contract and update token checkpoint.
        fn burn(ref self: ContractState, amount: u256) {
            let caller: ContractAddress = get_caller_address();
            let this: ContractAddress = get_contract_address();
            let reward_token = self.reward_token.read();

            let amount: u256 = if amount == BoundedInt::max() {
                reward_token.allowance(caller, this)
            } else {
                amount
            };

            if amount.is_non_zero() {
                reward_token.transfer_from(caller, this, amount);
                self.emit(RewardReceived { sender: caller, amount });

                if get_block_timestamp() > self.last_token_time.read() + TOKEN_CHECKPOINT_DEADLINE {
                    self.checkpoint_token_internal();
                }
            }
        }

        /// Update the token checkpoint.
        /// Calculates the total number of tokens to be distributed in a given week.
        fn checkpoint_token(ref self: ContractState) {
            assert!(
                get_block_timestamp() > self.last_token_time.read() + TOKEN_CHECKPOINT_DEADLINE,
                "Token checkpoint deadline not yet reached"
            );
            self.checkpoint_token_internal();
        }

        /// Update the veLORDS total supply checkpoint.
        /// The checkpoint is also updated by the first claimant each new epoch. This fn
        /// can be called independently of a claim to reduce claiming gas costs.
        fn checkpoint_total_supply(ref self: ContractState) {
            self.checkpoint_total_supply_internal();
        }

        /// Claim for an address.
        /// Each call to claim looks at max of 200 veLORDS checkpoints. This function may need
        /// to be called multiple times to claim all available fees. In the `Claimed` event
        /// this function emits, if the `claim_epoch` is less than `max_epoch`, the address
        /// may claim again.
        fn claim(ref self: ContractState, recipient: ContractAddress) -> u256 {
            let now: u64 = get_block_timestamp();

            if now >= self.time_cursor.read() {
                self.checkpoint_total_supply_internal();
            }

            let mut last_token_time: u64 = self.last_token_time.read();
            if now > last_token_time + TOKEN_CHECKPOINT_DEADLINE {
                self.checkpoint_token_internal();
                last_token_time = now;
            }

            let amount: u256 = self.claim_internal(recipient, floor_to_week(last_token_time));
            if amount.is_non_zero() {
                self.reward_token.read().transfer(recipient, amount);
                self.token_last_balance.write(self.token_last_balance.read() - amount);
            }

            amount
        }
    }

    #[generate_trait]
    impl InternalHelpers of InternalHelpersTrait {
        fn checkpoint_token_internal(ref self: ContractState) {
            let reward_token_balance: u256 = self.reward_token.read().balance_of(get_contract_address());
            let to_distribute: u256 = reward_token_balance - self.token_last_balance.read();
            let now: u64 = get_block_timestamp();

            if to_distribute.is_zero() {
                self.last_token_time.write(now);
                self.emit(CheckpointToken { time: now, tokens: 0 });
                return;
            }

            self.token_last_balance.write(reward_token_balance);
            let mut t: u64 = self.last_token_time.read();
            let since_last: u64 = now - t;
            self.last_token_time.write(now);
            let mut this_week: u64 = floor_to_week(now);
            let mut next_week: u64 = 0;
            let mut i: u32 = 0;

            while i < ITERATION_LIMIT {
                next_week = this_week + WEEK;
                let tpw = self.tokens_per_week.read(this_week);

                if now < next_week {
                    if (since_last.is_zero() && now == t) {
                        self.tokens_per_week.write(this_week, tpw + to_distribute);
                    } else {
                        self
                            .tokens_per_week
                            .write(this_week, tpw + to_distribute * (now - t).into() / since_last.into());
                    }
                    break;
                } else {
                    if (since_last.is_zero() && next_week == t) {
                        self.tokens_per_week.write(this_week, tpw + to_distribute);
                    } else {
                        self
                            .tokens_per_week
                            .write(this_week, tpw + to_distribute * (next_week - t).into() / since_last.into());
                    }
                }

                t = next_week;
                this_week = next_week;
            };

            self.emit(CheckpointToken { time: now, tokens: to_distribute })
        }

        fn checkpoint_total_supply_internal(ref self: ContractState) {
            let mut t: u64 = self.time_cursor.read();
            let rounded_ts: u64 = floor_to_week(get_block_timestamp());
            let velords = self.velords.read();
            velords.checkpoint();

            let mut i: u32 = 0;
            while i < ITERATION_LIMIT {
                if t > rounded_ts {
                    break;
                }

                let epoch: u64 = velords.find_epoch_by_timestamp(velords.contract_address, t);
                let point: Point = velords.get_point_for_at(velords.contract_address, epoch);
                let mut dt: i128 = 0;
                if t > point.ts {
                    // If the point is at 0 epoch, it can actually be earlier than the first deposit
                    // then make dt 0
                    dt = t.into() - point.ts.into();
                }
                let ve_supply: u128 = (point.bias - point.slope * dt)
                    .try_into()
                    .unwrap_or(0); // unwrap_or(0) is essentially a max(value, 0)
                self.ve_supply.write(t, ve_supply.into());

                t += WEEK;
            };

            self.time_cursor.write(t);
        }

        fn claim_internal(ref self: ContractState, recipient: ContractAddress, last_token_time: u64) -> u256 {
            let mut to_distribute: u256 = 0;
            let max_user_epoch: u64 = self.velords.read().get_epoch_for(recipient);
            let start_time: u64 = self.start_time.read();

            if max_user_epoch.is_zero() {
                // no lock -> no fees
                return 0;
            }

            let mut week_cursor: u64 = self.time_cursor_of.read(recipient);
            if week_cursor.is_zero() {
                let user_point: Point = self.velords.read().get_point_for_at(recipient, 1);
                week_cursor = floor_to_week(user_point.ts + WEEK - 1);
            }

            if week_cursor >= last_token_time {
                return 0;
            }

            if week_cursor < start_time {
                week_cursor = start_time;
            }

            let mut i: u32 = 0;
            while i < ITERATION_LIMIT {
                if week_cursor >= last_token_time {
                    break;
                }
                let balance_of: u256 = self.velords.read().balance_of_at(recipient, week_cursor);
                if balance_of.is_zero() {
                    break;
                }
                to_distribute += balance_of * self.tokens_per_week.read(week_cursor) / self.ve_supply.read(week_cursor);
                week_cursor += WEEK;
            };

            self.time_cursor_of.write(recipient, week_cursor);

            self
                .emit(
                    Claimed { recipient, amount: to_distribute, claim_epoch: week_cursor, max_epoch: max_user_epoch }
                );

            to_distribute
        }
    }

    //
    // Helper utility functions
    //

    fn floor_to_week(ts: u64) -> u64 {
        (ts / WEEK) * WEEK
    }
}
