use std::panic::panic_any;
use crate::consensus::consensus_kv::{kv_get, kv_put};
use crate::{bcat};

pub fn call_deploy(env: &mut crate::consensus::consensus_apply::ApplyEnv, args: Vec<Vec<u8>>) {
    if args.len() != 1 { panic_any("invalid_args") }
    let wasmbytes = args[0].as_slice();
    kv_put(env, &bcat(&[b"account:", env.caller_env.account_caller.as_slice(), b":meta:bytecode"]), wasmbytes);
}

pub fn bytecode(env: &mut crate::consensus::consensus_apply::ApplyEnv, account: &[u8]) -> Option<Vec<u8>> {
    kv_get(env, &bcat(&[b"account:", &account, b":meta:bytecode"]))
}
