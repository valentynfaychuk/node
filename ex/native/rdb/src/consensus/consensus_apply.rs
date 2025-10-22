use crate::{
    consensus, BoundColumnFamily, MultiThreaded, Transaction, TransactionDB, TransactionOptions, WriteOptions
};

use crate::consensus::bic::protocol;
use crate::consensus::consensus_kv;
use crate::consensus::consensus_muts;
use std::collections::HashMap;

pub struct CallerEnv {
    pub readonly: bool,
    pub seed: Option<Vec<u8>>,
    pub seedf64: f64,
    pub entry_signer: [u8; 48],
    pub entry_prev_hash: [u8; 32],
    pub entry_slot: u64,
    pub entry_prev_slot: u64,
    pub entry_height: u64,
    pub entry_epoch: u64,
    pub entry_vr: [u8; 96],
    pub entry_vr_b3: [u8; 32],
    pub entry_dr: [u8; 32],
    pub tx_index: u64,
    pub tx_signer: [u8; 48],
    pub tx_nonce: u64,
    pub tx_hash: [u8; 32],
    pub account_origin: Vec<u8>,
    pub account_caller: Vec<u8>,
    pub account_current: Vec<u8>,
    pub attached_symbol: String,
    pub attached_amount: String,
    pub call_counter: u32,
    pub call_exec_points: u64,
    pub call_exec_points_remaining: u64,
}

pub fn make_caller_env(
    entry_signer: &[u8; 48], entry_prev_hash: &[u8; 32],
    entry_slot: u64, entry_prev_slot: u64, entry_height: u64, entry_epoch: u64,
    entry_vr: &[u8; 96], entry_vr_b3: &[u8; 32], entry_dr: &[u8; 32],
) -> CallerEnv {
    CallerEnv {
        readonly: false,
        seed: None,
        seedf64: 1.0,
        entry_signer: *entry_signer,
        entry_prev_hash: *entry_prev_hash,
        entry_slot: entry_slot,
        entry_prev_slot: entry_prev_slot,
        entry_height: entry_height,
        entry_epoch: entry_epoch,
        entry_vr: *entry_vr,
        entry_vr_b3: *entry_vr_b3,
        entry_dr: *entry_dr,
        tx_index: 0,
        tx_signer: [0u8; 48],
        tx_nonce: 0,
        tx_hash: [0u8; 32],
        account_origin: Vec::new(),
        account_caller: Vec::new(),
        account_current: Vec::new(),
        attached_symbol: String::new(),
        attached_amount: String::new(),
        call_counter: 0,
        call_exec_points: 10_000_000,
        call_exec_points_remaining: 10_000_000,
    }
}

pub struct ApplyEnv<'db> {
    pub caller_env: CallerEnv,
    pub cf: std::sync::Arc<BoundColumnFamily<'db>>,
    pub txn: &'db mut Transaction<'db, TransactionDB<MultiThreaded>>,
    pub muts_final: Vec<consensus_muts::Mutation>,
    pub muts_final_rev: Vec<consensus_muts::Mutation>,
    pub muts: Vec<consensus_muts::Mutation>,
    pub muts_gas: Vec<consensus_muts::Mutation>,
    pub muts_rev: Vec<consensus_muts::Mutation>,
    pub muts_rev_gas: Vec<consensus_muts::Mutation>,
    pub result_log: Vec<HashMap<&'static str, &'static str>>,
}

pub fn make_apply_env<'db>(txn: &'db mut Transaction<'db, TransactionDB<MultiThreaded>>, cf: std::sync::Arc<BoundColumnFamily<'db>>,
    entry_signer: &[u8; 48], entry_prev_hash: &[u8; 32],
    entry_slot: u64, entry_prev_slot: u64, entry_height: u64, entry_epoch: u64,
    entry_vr: &[u8; 96], entry_vr_b3: &[u8; 32], entry_dr: &[u8; 32],
) -> ApplyEnv<'db> {
    ApplyEnv {
        caller_env: make_caller_env(entry_signer, entry_prev_hash, entry_slot, entry_prev_slot, entry_height, entry_epoch, entry_vr, entry_vr_b3, entry_dr),
        cf: cf,
        txn: txn,
        muts_final: Vec::new(),
        muts_final_rev: Vec::new(),
        muts: Vec::new(),
        muts_gas: Vec::new(),
        muts_rev: Vec::new(),
        muts_rev_gas: Vec::new(),
        result_log: Vec::new(),
    }
}

pub fn set_apply_env_tx<'db>(env: &mut ApplyEnv<'db>, tx_hash: &[u8; 32], tx_signer: &[u8; 48], tx_nonce: u64) {
    env.caller_env.tx_hash = *tx_hash;
    env.caller_env.tx_nonce = tx_nonce;
    env.caller_env.tx_signer = *tx_signer;
    env.caller_env.account_origin = tx_signer.to_vec();
}

pub fn apply_entry<'db, 'a>(db: &'db TransactionDB<MultiThreaded>, pk: &[u8], sk: &[u8],
    entry_signer: &[u8; 48], entry_prev_hash: &[u8; 32],
    entry_slot: u64, entry_prev_slot: u64, entry_height: u64, entry_epoch: u64,
    entry_vr: &[u8; 96], entry_vr_b3: &[u8; 32], entry_dr: &[u8; 32],
    txs_packed: Vec<Vec<u8>>, txus: Vec<rustler::Term<'a>>, txn: &'db mut Transaction<'db, TransactionDB>
) -> (Vec<consensus_muts::Mutation>, Vec<consensus_muts::Mutation>, Vec<HashMap<&'static str, &'static str>>) {
    let cf_h = db.cf_handle("contractstate").unwrap();

    let mut applyenv = make_apply_env(txn, cf_h, entry_signer, entry_prev_hash, entry_slot, entry_prev_slot, entry_height, entry_epoch, entry_vr, entry_vr_b3, entry_dr);

    call_txs_pre_upfront_cost(&mut applyenv, &txus);

    for (i, txu) in txus.into_iter().enumerate() {
        let tx_hash = crate::fixed::<32>(txu.map_get(crate::atoms::hash()).unwrap()).unwrap();
        let tx = txu.map_get(crate::atoms::tx()).unwrap();
        let tx_signer = crate::fixed::<48>(tx.map_get(crate::atoms::signer()).unwrap()).unwrap();
        let tx_nonce = tx.map_get(crate::atoms::nonce()).unwrap().decode::<u64>().unwrap();
        let action = tx.map_get(crate::atoms::actions()).unwrap().decode::<Vec<rustler::Term<'a>>>().unwrap();

        applyenv.caller_env.tx_index = i as u64;
        applyenv.caller_env.tx_hash = tx_hash;
        applyenv.caller_env.tx_signer = tx_signer;
        applyenv.caller_env.tx_nonce = tx_nonce;
        applyenv.caller_env.account_origin = tx_signer.to_vec();
        applyenv.caller_env.account_caller = tx_signer.to_vec();

        match action.first() {
            None => {
                let mut m: HashMap<&'static str, &'static str> = HashMap::new();
                m.insert("error", "no_actions");
                applyenv.result_log.push(m);
            },
            Some(action) => {
                //let op = action.map_get(crate::atoms::op()).unwrap().decode::<rustler::Binary>().unwrap().as_slice();
                let contract = action.map_get(crate::atoms::contract()).unwrap().decode::<rustler::Binary>().unwrap().to_vec();
                let function = action.map_get(crate::atoms::function()).unwrap().decode::<rustler::Binary>().unwrap().to_vec();
                let args = action.map_get(crate::atoms::args()).unwrap().decode::<Vec<Vec<u8>>>().unwrap().to_vec();
                let attached_symbol = action.map_get(crate::atoms::attached_symbol()).ok().and_then(|t| t.decode::<Option<Vec<u8>>>().unwrap());
                let attached_amount = action.map_get(crate::atoms::attached_amount()).ok().and_then(|t| t.decode::<Option<Vec<u8>>>().unwrap());

                applyenv.caller_env.account_current = contract.to_vec();
                applyenv.muts = Vec::new();
                applyenv.muts_rev = Vec::new();
                applyenv.muts_gas = Vec::new();
                applyenv.muts_rev_gas = Vec::new();

                //println!("{:?} {:?} {:?} {:?} {:?}", op, contract, function, attached_amount, attached_symbol);
                let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    match consensus::bls12_381::validate_public_key(contract.as_slice()) {
                        false => call_bic(&mut applyenv, contract, function, args, attached_symbol, attached_amount),
                        true => call_wasmvm(&mut applyenv, contract, function, args, attached_symbol, attached_amount)
                    }
                }));
                match res {
                    Ok(_) => {
                        let mut m: HashMap<&'static str, &'static str> = HashMap::new();
                        m.insert("error", "ok");
                        applyenv.muts_final.append(&mut applyenv.muts);
                        applyenv.muts_final.append(&mut applyenv.muts_gas);
                        applyenv.muts_final_rev.append(&mut applyenv.muts_rev);
                        applyenv.muts_final_rev.append(&mut applyenv.muts_rev_gas);
                    }
                    Err(payload) => {
                        applyenv.muts_final.append(&mut applyenv.muts_gas);
                        applyenv.muts_final_rev.append(&mut applyenv.muts_rev_gas);

                        consensus_kv::revert(&mut applyenv);

                        if let Some(&s) = payload.downcast_ref::<&'static str>() {
                            let mut m: HashMap<&'static str, &'static str> = HashMap::new();
                            m.insert("error", s);
                            applyenv.result_log.push(m);
                        } else {
                            let mut m: HashMap<&'static str, &'static str> = HashMap::new();
                            m.insert("error", "unknown");
                            applyenv.result_log.push(m);
                        }
                    }
                }
            }
        }
    }

    call_exit(&mut applyenv);

    (applyenv.muts, applyenv.muts_rev, applyenv.result_log)
}

fn call_exit(env: &mut ApplyEnv) {
    env.muts = Vec::new();
    env.muts_rev = Vec::new();

    if env.caller_env.entry_height % 1000 == 0 {
        let digest = blake3::hash(&env.caller_env.entry_vr);
        consensus_kv::kv_put(env, b"bic:epoch:segment_vr_hash", digest.as_bytes());
    }
    if env.caller_env.entry_height % 100_000 == 99_999 {
        consensus::bic::epoch::next(env);
    }

    env.muts_final.append(&mut env.muts);
    env.muts_final_rev.append(&mut env.muts_rev);
}

fn call_txs_pre_upfront_cost<'a>(env: &mut ApplyEnv, txus: &[rustler::Term<'a>]) {
    env.muts = Vec::new();
    env.muts_rev = Vec::new();
    for txu in txus {
        let tx_encoded = txu.map_get(crate::atoms::tx_encoded()).unwrap().decode::<rustler::Binary>().unwrap().as_slice();
        let tx_hash = crate::fixed::<32>(txu.map_get(crate::atoms::hash()).unwrap()).unwrap();
        let tx = txu.map_get(crate::atoms::tx()).unwrap();
        let tx_signer = crate::fixed::<48>(tx.map_get(crate::atoms::signer()).unwrap()).unwrap();
        let tx_nonce = tx.map_get(crate::atoms::nonce()).unwrap().decode::<u64>().unwrap();

        set_apply_env_tx(env, &tx_hash, &tx_signer, tx_nonce);

        // Update nonce
        consensus_kv::kv_put(env, &crate::bcat(&[b"bic:base:nonce:", &tx_signer]), &tx_nonce.to_string().into_bytes());
        // Deduct tx cost
        let tx_cost = protocol::tx_cost_per_byte(env.caller_env.entry_epoch, tx_encoded.len());
        protocol::pay_cost(env, tx_cost);
    }
    env.muts_final.append(&mut env.muts);
    env.muts_final_rev.append(&mut env.muts_rev);
}

pub fn valid_bic_action(contract: Vec<u8>, function: Vec<u8>) -> bool {
    let c = contract.as_slice();
    let f = function.as_slice();

    (c == b"Epoch" || c == b"Coin" || c == b"Contract")
        && (f == b"submit_sol"
            || f == b"transfer"
            || f == b"set_emission_address"
            || f == b"slash_trainer"
            || f == b"deploy"
            || f == b"create_and_mint"
            || f == b"mint"
            || f == b"pause")
}

fn call_bic(env: &mut ApplyEnv, contract: Vec<u8>, function: Vec<u8>, args: Vec<Vec<u8>>, attached_symbol: Option<Vec<u8>>, attached_amount: Option<Vec<u8>>) {
    match valid_bic_action(contract.to_vec(), function.to_vec()) {
        false => {
            let mut m: HashMap<&'static str, &'static str> = HashMap::new();
            m.insert("error", "invalid_bic_action");
            env.result_log.push(m);
        }
        true => {
            match (contract.as_slice(), function.as_slice()) {
                (b"Coin", b"transfer") => consensus::bic::coin::call_transfer(env, args),
                (b"Coin", b"create_and_mint") => consensus::bic::coin::call_create_and_mint(env, args),
                (b"Coin", b"mint") => consensus::bic::coin::call_mint(env, args),
                (b"Coin", b"pause") => consensus::bic::coin::call_pause(env, args),
                _ => ()
            }
        }
    }
}

fn call_wasmvm(env: &mut ApplyEnv, contract: Vec<u8>, function: Vec<u8>, args: Vec<Vec<u8>>, attached_symbol: Option<Vec<u8>>, attached_amount: Option<Vec<u8>>) {
}
