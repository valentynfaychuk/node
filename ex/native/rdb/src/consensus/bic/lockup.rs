use std::panic::panic_any;
use crate::consensus::consensus_apply::ApplyEnv;
use crate::{bcat};
use crate::consensus::{consensus_kv::{kv_get, kv_increment, kv_put, kv_delete}};

pub fn create_lock(env: &mut ApplyEnv, receiver: &[u8], symbol: &[u8], amount: i128, unlock_epoch: u64) {
    if amount <= 0 { panic_any("invalid_amount") }

    let vault_index = kv_increment(env, &bcat(&[b"bic:lockup:unique_index"]), 1);
    let vault_value = bcat(&[
        unlock_epoch.to_string().as_bytes(),
        b"-", amount.to_string().as_bytes(),
        b"-", &symbol,
    ]);
    kv_put(env, &bcat(&[b"bic:lockup:vault:", &receiver, b":", vault_index.to_string().as_bytes()]), &vault_value);
}

pub fn call_unlock(env: &mut crate::consensus::consensus_apply::ApplyEnv, args: Vec<Vec<u8>>) {
    if args.len() != 1 { panic_any("invalid_args") }
    let vault_index = args[0].as_slice();

    let vault_key = &bcat(&[b"bic:lockup:vault:", &env.caller_env.account_caller, b":", vault_index]);

    let vault = kv_get(env, vault_key);
    if vault.is_none() { panic_any("invalid_vault") }
    let vault = vault.unwrap();

    let vault_parts: Vec<Vec<u8>> = vault.split(|&b| b == b'-').map(|seg| seg.to_vec()).collect();
    let unlock_epoch = vault_parts[0].as_slice();
    let unlock_epoch = std::str::from_utf8(&unlock_epoch).ok().and_then(|s| s.parse::<u64>().ok()).unwrap_or_else(|| panic_any("invalid_unlock_epoch"));
    let amount = vault_parts[1].as_slice();
    let amount = std::str::from_utf8(&amount).ok().and_then(|s| s.parse::<u64>().ok()).unwrap_or_else(|| panic_any("invalid_unlock_amount"));
    let symbol = vault_parts[2].as_slice();

    if env.caller_env.entry_epoch < unlock_epoch {
        panic_any("vault_is_locked")
    } else {
        kv_increment(env, &bcat(&[b"bic:coin:balance:", &env.caller_env.account_caller, &symbol]), amount as i128);
        kv_delete(env, vault_key);
    }
}
