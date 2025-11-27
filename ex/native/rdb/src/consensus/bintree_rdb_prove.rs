use rust_rocksdb::{DBRawIteratorWithThreadMode, TransactionDB, MultiThreaded};
use sha2::{Digest, Sha256};
use std::cmp::{min, Ordering};
use std::convert::TryInto;

use crate::consensus::bintree::{compute_namespace_path};

// ============================================================================
// TYPES & CONSTANTS
// ============================================================================

// DEFINE THE SPECIFIC ITERATOR TYPE FOR TransactionDB<MultiThreaded>
// This fixes the "mismatched types" error.
pub type Iter<'a> = DBRawIteratorWithThreadMode<'a, TransactionDB<MultiThreaded>>;

pub type Hash = [u8; 32];
pub type Path = [u8; 32];
pub const ZERO_HASH: Hash = [0u8; 32];

#[derive(Debug, Clone, PartialEq, Eq, Copy)]
pub struct NodeKey {
    pub path: Path,
    pub len: u16,
}

impl PartialOrd for NodeKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for NodeKey {
    fn cmp(&self, other: &Self) -> Ordering {
        match self.path.cmp(&other.path) {
            Ordering::Equal => self.len.cmp(&other.len),
            other => other,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ProofNode {
    pub hash: Hash,
    pub direction: u8,
}

#[derive(Debug, Clone)]
pub struct Proof {
    pub root: Hash,
    pub nodes: Vec<ProofNode>,
    pub path: Path,
    pub hash: Hash,
}

// ============================================================================
// BIT & HASH HELPERS
// ============================================================================

#[inline(always)]
fn get_bit_be(data: &[u8], index: u16) -> u8 {
    if index >= 256 { return 0; }
    let byte_idx = (index >> 3) as usize;
    let bit_offset = 7 - (index & 7);
    (data[byte_idx] >> bit_offset) & 1
}

#[inline(always)]
fn set_bit_be(data: &mut [u8], index: u16, val: u8) {
    if index >= 256 { return; }
    let byte_idx = (index >> 3) as usize;
    let bit_offset = 7 - (index & 7);
    if val == 1 { data[byte_idx] |= 1 << bit_offset; }
    else { data[byte_idx] &= !(1 << bit_offset); }
}

#[inline]
fn mask_after_be(data: &mut [u8], len: u16) {
    if len >= 256 { return; }
    let byte_idx = (len >> 3) as usize;
    let start_clean_bit = len;
    for i in start_clean_bit..((byte_idx as u16 + 1) << 3) {
        let off = 7 - (i & 7);
        data[byte_idx] &= !(1 << off);
    }
    if byte_idx + 1 < 32 { data[(byte_idx + 1)..].fill(0); }
}

#[inline]
fn lcp_be(p1: &Path, p2: &Path) -> (Path, u16) {
    let mut len = 0;
    let mut byte_idx = 0;
    while byte_idx < 32 && p1[byte_idx] == p2[byte_idx] {
        len += 8;
        byte_idx += 1;
    }
    if byte_idx < 32 {
        for i in 0..8 {
            let idx = (byte_idx << 3) + i;
            if get_bit_be(p1, idx as u16) == get_bit_be(p2, idx as u16) { len += 1; }
            else { break; }
        }
    }
    let mut prefix = *p1;
    mask_after_be(&mut prefix, len);
    (prefix, len)
}

#[inline]
fn prefix_match_be(target: &Path, path: &Path, len: u16) -> bool {
    let full_bytes = (len >> 3) as usize;
    if target[..full_bytes] != path[..full_bytes] { return false; }
    let rem = len & 7;
    if rem > 0 {
        let mask = 0xFF << (8 - rem);
        if (target[full_bytes] & mask) != (path[full_bytes] & mask) { return false; }
    }
    true
}

#[inline]
fn sha256(data: &[u8]) -> Hash {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().into()
}

// ============================================================================
// ROCKSDB SERIALIZATION HELPERS
// ============================================================================

#[inline]
fn serialize_key(key: &NodeKey) -> Vec<u8> {
    let mut v = Vec::with_capacity(39);
    v.extend_from_slice(b"tree:");
    v.extend_from_slice(&key.path);
    v.extend_from_slice(&key.len.to_be_bytes());
    v
}

#[inline]
fn deserialize_key(data: &[u8]) -> NodeKey {
    let data = &data[5..];
    let mut path = [0u8; 32];
    path.copy_from_slice(&data[0..32]);
    let len = u16::from_be_bytes([data[32], data[33]]);
    NodeKey { path, len }
}

// ============================================================================
// PROVER MODULE
// ============================================================================

pub struct RocksHubtProveViaIterator;

impl RocksHubtProveViaIterator {

    // CHANGED: iter type from DBRawIterator to Iter (the alias for TransactionDB iterator)
    pub fn prove(
        iter: &mut Iter,
        ns: Option<&[u8]>,
        k: &[u8]
    ) -> Proof {
        let target_path = compute_namespace_path(ns, k);

        let root_hash = Self::get_root(iter);

        let (found_key, found_hash) = match Self::find_longest_prefix_node(iter, &target_path) {
            Some((key, hash)) => (key, hash),
            None => {
                return Proof {
                    root: ZERO_HASH,
                    nodes: vec![],
                    path: ZERO_HASH,
                    hash: ZERO_HASH
                };
            }
        };

        Proof {
            root: root_hash,
            nodes: Self::generate_proof_nodes(iter, found_key.path, found_key.len),
            path: found_key.path,
            hash: found_hash,
        }
    }

    // ========================================================================
    // INTERNAL LOGIC (Using Iter)
    // ========================================================================

    fn get_root(iter: &mut Iter) -> Hash {
        iter.seek_to_first();
        if iter.valid() {
            iter.value().unwrap().try_into().unwrap()
        } else {
            ZERO_HASH
        }
    }

    fn find_longest_prefix_node(
        iter: &mut Iter,
        target: &Path
    ) -> Option<(NodeKey, Hash)> {
        let s_key = NodeKey { path: *target, len: 256 };

        let prev = Self::seek_prev(iter, &s_key);
        let next = Self::seek_next(iter, &s_key);

        match (prev, next) {
            (None, None) => None,
            (None, Some((k, h))) => Some((k, h)),
            (Some((k, h)), None) => Some((k, h)),
            (Some((pk, ph)), Some((nk, nh))) => {
                let (_, rp) = lcp_be(target, &pk.path);
                let (_, rn) = lcp_be(target, &nk.path);
                if min(rp, pk.len) >= min(rn, nk.len) {
                    Some((pk, ph))
                } else {
                    Some((nk, nh))
                }
            }
        }
    }

    fn generate_proof_nodes(
        iter: &mut Iter,
        path: Path,
        len: u16
    ) -> Vec<ProofNode> {
        let mut ancestors = Vec::new();
        let mut cursor = NodeKey { path, len: 256 };

        loop {
            match Self::seek_prev(iter, &cursor) {
                None => break,
                Some((k, _)) => {
                    let is_same = k == cursor;
                    if prefix_match_be(&path, &k.path, k.len) {
                        if k.len < len { ancestors.push(k); }
                        if k.len > 0 {
                            cursor = NodeKey { path: k.path, len: k.len - 1 };
                        } else {
                            break;
                        }
                    } else {
                        let (lcp_p, lcp_l) = lcp_be(&path, &k.path);
                        let jump = NodeKey { path: lcp_p, len: lcp_l + 1 };
                        if jump < k {
                            cursor = jump;
                        } else if is_same {
                            if k.len > 0 { cursor = NodeKey{path: k.path, len: k.len - 1}; } else { break; }
                        } else {
                            cursor = k;
                        }
                    }
                }
            }
        }

        ancestors.sort_unstable_by(|a, b| b.len.cmp(&a.len));

        let mut nodes = Vec::new();
        for anc in ancestors {
            let my_dir = get_bit_be(&path, anc.len);
            let sibling_dir = 1 - my_dir;

            let mut t_path = anc.path;
            set_bit_be(&mut t_path, anc.len, sibling_dir);
            mask_after_be(&mut t_path, anc.len + 1);
            let t_key = NodeKey { path: t_path, len: anc.len + 1 };

            let s_hash = Self::seek_next_inclusive(iter, &t_key)
                .filter(|(k, _)| prefix_match_be(&k.path, &t_path, anc.len + 1))
                .map(|(_, h)| h)
                .unwrap_or(ZERO_HASH);

            nodes.push(ProofNode {
                hash: s_hash,
                direction: sibling_dir
            });
        }
        nodes
    }

    // ========================================================================
    // ITERATOR WRAPPERS (Using Iter)
    // ========================================================================

    fn seek_prev(iter: &mut Iter, key: &NodeKey) -> Option<(NodeKey, Hash)> {
        let k_bytes = serialize_key(key);
        iter.seek_for_prev(k_bytes);
        if iter.valid() {
            let found_k = deserialize_key(iter.key().unwrap());
            let found_v: Hash = iter.value().unwrap().try_into().unwrap();
            Some((found_k, found_v))
        } else {
            None
        }
    }

    fn seek_next(iter: &mut Iter, key: &NodeKey) -> Option<(NodeKey, Hash)> {
        let k_bytes = serialize_key(key);
        iter.seek(k_bytes);
        if iter.valid() {
            let found_k = deserialize_key(iter.key().unwrap());
            if found_k == *key {
                iter.next();
            }
        }
        if iter.valid() {
            let found_k = deserialize_key(iter.key().unwrap());
            let found_v: Hash = iter.value().unwrap().try_into().unwrap();
            Some((found_k, found_v))
        } else {
            None
        }
    }

    fn seek_next_inclusive(iter: &mut Iter, key: &NodeKey) -> Option<(NodeKey, Hash)> {
        let k_bytes = serialize_key(key);
        iter.seek(k_bytes);
        if iter.valid() {
            let found_k = deserialize_key(iter.key().unwrap());
            let found_v: Hash = iter.value().unwrap().try_into().unwrap();
            Some((found_k, found_v))
        } else {
            None
        }
    }
}
