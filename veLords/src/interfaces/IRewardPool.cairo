use starknet::ContractAddress;

#[starknet::interface]
pub trait IRewardPool<TContractState> {
    // TODO: docs

    //
    // getters
    //

    fn get_reward_token(self: @TContractState) -> ContractAddress;
    fn get_start_time(self: @TContractState) -> u64;
    fn get_time_cursor(self: @TContractState) -> u64;
    fn get_time_cursor_of(self: @TContractState, account: ContractAddress) -> u64;
    fn get_last_token_time(self: @TContractState) -> u64;
    fn get_tokens_per_week(self: @TContractState, week: u64) -> u256;
    fn get_token_last_balance(self: @TContractState) -> u256;
    fn get_ve_supply(self: @TContractState, week: u64) -> u256;

    //
    // modifiers
    //

    fn burn(ref self: TContractState, amount: u256);
    fn checkpoint_token(ref self: TContractState);
    fn checkpoint_total_supply(ref self: TContractState);
    fn claim(ref self: TContractState, recipient: ContractAddress) -> u256;
}
