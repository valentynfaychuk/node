use crate::consensus::bic::coin;
use crate::consensus::consensus_kv;

pub const FORKHEIGHT: u64 = 419_00000;
//pub const FORKHEIGHT: u64 = 100;

pub const AMA_1_DOLLAR: i128 = 1_000_000_000;
pub const AMA_10_CENT: i128 =    100_000_000;
pub const AMA_1_CENT: i128 =      10_000_000;

pub const RESERVE_AMA_PER_TX: i128 = AMA_10_CENT; //reserved for exec balance (refunded at end of TX execution)

pub const COST_PER_BYTE_HISTORICAL: i128 = 6_666; //cost to increase the ledger size
pub const COST_PER_BYTE_STATE: i128 = 16_666; //cost to grow the contract state
pub const COST_PER_OP_WASM: i128 = 1; //cost to execute a wasm op

pub const COST_PER_DB_READ_BASE: i128 = 5_000;
pub const COST_PER_DB_READ_BYTE: i128 = 50;
pub const COST_PER_DB_WRITE_BASE: i128 = 25_000;
pub const COST_PER_DB_WRITE_BYTE: i128 = 250;

pub const COST_PER_SOL: i128 = AMA_1_CENT; //cost to submit_sol
pub const COST_PER_NEW_LEAF_MERKLE: i128 = COST_PER_BYTE_STATE * 128; //cost to grow the merkle tree

pub fn pay_cost(env: &mut crate::consensus::consensus_apply::ApplyEnv, cost: i128) {
    consensus_kv::kv_increment(env, &crate::bcat(&[b"account:", &env.caller_env.account_origin, b":balance:AMA"]), -cost);
    // Increment validator / burn
    consensus_kv::kv_increment(env, &crate::bcat(&[b"account:", &env.caller_env.entry_signer, b":balance:AMA"]), cost/2);
    consensus_kv::kv_increment(env, &crate::bcat(&[b"account:", &coin::BURN_ADDRESS, b":balance:AMA"]), cost/2);
}
