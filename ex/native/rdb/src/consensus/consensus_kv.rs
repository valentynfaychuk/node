use std::panic::panic_any;

use crate::consensus::consensus_apply;
use consensus_apply::ApplyEnv;

use crate::consensus::consensus_muts;
use consensus_muts::Mutation;

pub fn kv_put(env: &mut ApplyEnv, key: &[u8], value: &[u8]) {
    let old_value = env.txn.get_cf(&env.cf, key).unwrap();
    env.txn.put_cf(&env.cf, key, value).unwrap_or_else(|_| panic_any("kv_put_failed"));

    env.muts.push(Mutation::Put { op: b"put".to_vec(), key: key.to_vec(), value: value.to_vec() });
    match old_value {
        None => env.muts_rev.push(Mutation::Delete { op: b"delete".to_vec(), key: key.to_vec() }),
        Some(old) => env.muts_rev.push(Mutation::Put { op: b"put".to_vec(), key: key.to_vec(), value: old.to_vec() })
    }
}

pub fn kv_increment(env: &mut ApplyEnv, key: &[u8], value: i128) -> i128 {
    match env.txn.get_cf(&env.cf, key).unwrap() {
        None => {
            env.muts.push(Mutation::Put { op: b"put".to_vec(), key: key.to_vec(), value: value.to_string().into_bytes() });
            env.muts_rev.push(Mutation::Delete { op: b"delete".to_vec(), key: key.to_vec() });
            env.txn.put_cf(&env.cf, key, value.to_string().into_bytes()).unwrap_or_else(|_| panic_any("kv_put_failed"));
            value
        },
        Some(old) => {
            let new_value: i128 = atoi::atoi::<i128>(&old).ok_or("invalid_integer").unwrap() + value;
            env.muts.push(Mutation::Put { op: b"put".to_vec(), key: key.to_vec(), value: new_value.to_string().into_bytes() });
            env.muts_rev.push(Mutation::Put { op: b"put".to_vec(), key: key.to_vec(), value: old });
            env.txn.put_cf(&env.cf, key, new_value.to_string().into_bytes()).unwrap_or_else(|_| panic_any("kv_put_failed"));
            new_value
        }
    }
}

pub fn kv_delete(env: &mut ApplyEnv, key: &[u8]) {
    match env.txn.get_cf(&env.cf, key).unwrap() {
        None => (),
        Some(old) => {
            env.muts.push(Mutation::Delete { op: b"delete".to_vec(), key: key.to_vec() });
            env.muts_rev.push(Mutation::Put { op: b"put".to_vec(), key: key.to_vec(), value: old.to_vec() })
        }
    }
    env.txn.delete_cf(&env.cf, key).unwrap_or_else(|_| panic_any("kv_put_failed"));
}

pub fn kv_set_bit(env: &mut ApplyEnv, key: &[u8], bit_idx: u64) -> bool {
    let (mut old, exists) = match env.txn.get_cf(&env.cf, key).unwrap() {
        None => (vec![0u8; crate::consensus::bic::sol_bloom::PAGE_SIZE as usize], false),
        Some(value) => (value, true)
    };

    let byte_idx = (bit_idx / 8) as usize;
    let bit_in_byte = (bit_idx % 8) as u8;
    let mask: u8 = 1u8 << (7 - bit_in_byte);

    if (old[byte_idx] & mask) != 0 {
        false
    } else {
        env.muts.push(Mutation::SetBit { op: b"set_bit".to_vec(), key: key.to_vec(), value: bit_idx, bloomsize: crate::consensus::bic::sol_bloom::PAGE_SIZE});
        match exists {
            true => env.muts_rev.push(Mutation::ClearBit { op: b"clear_bit".to_vec(), key: key.to_vec(), value: bit_idx}),
            false => env.muts_rev.push(Mutation::Delete { op: b"delete".to_vec(), key: key.to_vec()})
        };
        old[byte_idx] |= mask;
        env.txn.put_cf(&env.cf, key, &old).unwrap();
        true
    }
}

pub fn kv_exists(env: &mut ApplyEnv, key: &[u8]) -> bool {
    match env.txn.get_cf(&env.cf, key).unwrap() {
        None => false,
        Some(_) => true
    }
}

pub fn kv_get(env: &ApplyEnv, key: &[u8]) -> Option<Vec<u8>> {
    env.txn.get_cf(&env.cf, key).unwrap()
}

pub fn kv_get_next(env: &mut ApplyEnv, prefix: &[u8], key: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let seek = [prefix, key].concat();

    let mut it = env.txn.raw_iterator_cf(&env.cf);
    it.seek(&seek);
    let it_valid = it.valid();
    if !it_valid { return None};
    if let Some(k) = it.key() {
        if k == &seek {
            it.next();
        }
    }

    match it.item() {
        Some((k, v)) if k.starts_with(prefix) => {
            let next_key_wo_prefix = k[prefix.len()..].to_vec();
            Some((next_key_wo_prefix, v.to_vec()))
        },
        _ => None
    }
}

pub fn kv_get_prev(env: &mut ApplyEnv, prefix: &[u8], key: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let seek = [prefix, key].concat();

    let mut it = env.txn.raw_iterator_cf(&env.cf);
    it.seek_for_prev(&seek);
    let it_valid = it.valid();
    if !it_valid { return None};
    if let Some(k) = it.key() {
        if k == &seek {
            it.prev();
        }
    }

    match it.item() {
        Some((k, v)) if k.starts_with(prefix) => {
            let next_key_wo_prefix = k[prefix.len()..].to_vec();
            Some((next_key_wo_prefix, v.to_vec()))
        },
        _ => None
    }
}

pub fn kv_get_prev_or_first(env: &ApplyEnv, prefix: &[u8], key: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let seek = [prefix, key].concat();

    let mut it = env.txn.raw_iterator_cf(&env.cf);
    it.seek_for_prev(&seek);

    match it.item() {
        Some((k, v)) => {
            if k.starts_with(prefix) {
                let next_key_wo_prefix = k[prefix.len()..].to_vec();
                Some((next_key_wo_prefix, v.to_vec()))
            } else {
                None
            }
        },
        None => None,
    }
}

pub fn contractstate_namespace(key: &[u8]) -> Option<Vec<u8>> {
    if key.starts_with(b"account:") {
        Some(key[0..56].to_vec())
    } else if key.starts_with(b"coin") {
        Some(b"coin".to_vec())
    } else if key.starts_with(b"bic") {
        Some(b"bic".to_vec())
    } else {
        None
    }
}

pub fn revert(env: &mut ApplyEnv) {
    for m in env.muts_rev.clone().iter().rev() {
        match m {
            Mutation::Put { op, key, value } => {
                env.txn.put_cf(&env.cf, key, value).unwrap();
            }
            Mutation::Delete { op, key } => {
                env.txn.delete_cf(&env.cf, key).unwrap();
            }
            Mutation::SetBit { op, key, value, bloomsize } => {
            }
            Mutation::ClearBit { op, key, value } => {
                let bit_idx = value;
                if let Some(mut old) = kv_get(env, key.as_slice()) {
                    let byte_idx   = (bit_idx / 8) as usize;
                    let bit_in     = (bit_idx % 8) as u8;      // 0..=7, MSB-first
                    if byte_idx < old.len() {
                        let mask: u8 = 1u8 << (7 - bit_in);
                        // Force bit to 0 (idempotent)
                        old[byte_idx] &= !mask;
                        env.txn.put_cf(&env.cf, key, &old).unwrap();
                    }
                }
            }
        }
    }
}
