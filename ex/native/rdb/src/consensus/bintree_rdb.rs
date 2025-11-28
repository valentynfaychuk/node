use crate::consensus::{self, consensus_apply};
use consensus_apply::ApplyEnv;
use crate::consensus::consensus_kv::{kv_put, kv_delete};
use crate::consensus::bintree::{compute_namespace_path, Proof, ProofNode, NodeKey, VerifyStatus};

use sha2::{Digest, Sha256};
use rayon::prelude::*;
use std::cmp::{min, Ordering};
use std::collections::BTreeSet;
use std::convert::TryInto;
use std::ops::Bound; // conceptually used

// ============================================================================
// TYPES & CONSTANTS
// ============================================================================

pub type Hash = [u8; 32];
pub type Path = [u8; 32];
const ZERO_HASH: Hash = [0u8; 32];

#[derive(Debug, Clone)]
pub enum Op {
    Insert(Option<Vec<u8>>, Vec<u8>, Vec<u8>),
    Delete(Option<Vec<u8>>, Vec<u8>),
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

#[inline]
fn concat_and_hash(a: &[u8], b: &[u8]) -> Hash {
    let mut hasher = Sha256::new();
    hasher.update(a);
    hasher.update(b);
    hasher.finalize().into()
}

// ============================================================================
// ROCKSDB SERIALIZATION HELPERS
// ============================================================================

#[inline]
fn serialize_key(key: &NodeKey) -> Vec<u8> {
    let mut v = Vec::with_capacity(34);
    v.extend_from_slice(&key.path);
    v.extend_from_slice(&key.len.to_be_bytes());
    v
}

#[inline]
fn deserialize_key(data: &[u8]) -> NodeKey {
    let mut path = [0u8; 32];
    path.copy_from_slice(&data[0..32]);
    let len = u16::from_be_bytes([data[32], data[33]]);
    NodeKey { path, len }
}

// ============================================================================
// ROCKSDB HUBT
// ============================================================================

pub struct RocksHubt<'env, 'a> {
    env: &'env mut ApplyEnv<'a>,
}

impl<'env, 'a> RocksHubt<'env, 'a> {
    pub fn new(env: &'env mut ApplyEnv<'a>) -> Self {
        Self { env }
    }

    pub fn root(&self) -> Hash {
        // Root is the smallest key in the DB (usually 00..00 len 0)
        let mut iter = self.env.txn.raw_iterator_cf(&self.env.cf);
        iter.seek_to_first();
        if iter.valid() {
            iter.value().unwrap().try_into().unwrap()
        } else {
            ZERO_HASH
        }
    }

    // ========================================================================
    // BATCH UPDATE (Same logic as before, verified)
    // ========================================================================
    pub fn batch_update(&mut self, ops: Vec<Op>) {
        let mut prepared: Vec<(bool, Path, Hash)> = ops.into_par_iter().map(|op| {
            match op {
                Op::Insert(ns, k, v) => {
                    let path = compute_namespace_path(ns.as_deref(), &k);
                    (true, path, concat_and_hash(&k, &v))
                },
                Op::Delete(ns, k) => {
                    let path = compute_namespace_path(ns.as_deref(), &k);
                    (false, path, ZERO_HASH)
                }
            }
        }).collect();

        prepared.par_sort_unstable_by(|a, b| a.1.cmp(&b.1));

        let mut dirty_set = BTreeSet::new();

        for (is_ins, p, _) in &prepared {
            if !*is_ins {
                let key = NodeKey { path: *p, len: 256 };
                self.remove_raw(&key);
            }
        }

        for (is_ins, p, l) in &prepared {
            if *is_ins {
                let key = NodeKey { path: *p, len: 256 };
                self.insert_raw(key, *l);
                dirty_set.insert(key);
            }
        }

        for window in prepared.windows(2) {
            let (lcp_p, lcp_len) = lcp_be(&window[0].1, &window[1].1);
            let key = NodeKey { path: lcp_p, len: lcp_len };
            self.ensure_node_exists(key, &mut dirty_set);
        }

        for (is_ins, p, _) in &prepared {
            if *is_ins {
                self.ensure_split_points(*p, &mut dirty_set);
            }
        }

        for (_, p, _) in &prepared {
            self.collect_dirty_ancestors(*p, &mut dirty_set);
        }

        self.rehash_and_prune(dirty_set);
    }

    // ========================================================================
    // UNIFIED PROOF LOGIC (NEW)
    // ========================================================================

    /// Generates the Unified Proof covering Inclusion, Mismatch, or Non-Existence.
    pub fn prove(&self, ns: Option<&[u8]>, k: &[u8]) -> Proof {
        let target_path = compute_namespace_path(ns, k);

        // 1. Find the node that actually exists (Exact Match OR Longest Prefix)
        let (found_key, found_hash) = match self.find_longest_prefix_node(&target_path) {
            Some((key, hash)) => (key, hash),
            None => {
                // Empty tree case
                return Proof {
                    root: ZERO_HASH,
                    nodes: vec![],
                    path: ZERO_HASH,
                    hash: ZERO_HASH
                };
            }
        };

        // 2. Generate Merkle path to that node
        Proof {
            root: self.root(),
            nodes: self.generate_proof_nodes(found_key.path, found_key.len),
            path: found_key.path,
            hash: found_hash,
        }
    }

    /// Finds the node in the DB that shares the longest prefix with the target.
    /// Used to prove existence (if path matches) or non-existence (returns divergence point).
    fn find_longest_prefix_node(&self, target: &Path) -> Option<(NodeKey, Hash)> {
        let s_key = NodeKey { path: *target, len: 256 };

        // Finds node <= s_key (Predecessor or Exact)
        let prev = self.seek_prev(&s_key);

        // Finds node > s_key (Strict Successor)
        let next = self.seek_next(&s_key);

        match (prev, next) {
            (None, None) => None,
            (None, Some((k, h))) => Some((k, h)),
            (Some((k, h)), None) => Some((k, h)),
            (Some((pk, ph)), Some((nk, nh))) => {
                // Compare which one is "closer" to the target via LCP
                let (_, rp) = lcp_be(target, &pk.path);
                let (_, rn) = lcp_be(target, &nk.path);

                // If the predecessor shares a longer (or equal) prefix length, pick it.
                // Note: pk.len is crucial. A shorter internal node might be an ancestor,
                // but we want the specific divergence point.
                if min(rp, pk.len) >= min(rn, nk.len) {
                    Some((pk, ph))
                } else {
                    Some((nk, nh))
                }
            }
        }
    }

    fn generate_proof_nodes(&self, path: Path, len: u16) -> Vec<ProofNode> {
        let mut ancestors = Vec::new();
        let mut cursor = NodeKey { path, len: 256 };

        // Walk up from leaf/found node to root
        loop {
            match self.seek_prev(&cursor) {
                None => break,
                Some((k, _)) => {
                    let is_same = k == cursor;
                    if prefix_match_be(&path, &k.path, k.len) {
                        // It's an ancestor
                        if k.len < len { ancestors.push(k); }
                        if k.len > 0 {
                            cursor = NodeKey { path: k.path, len: k.len - 1 };
                        } else {
                            break;
                        }
                    } else {
                        // Not an ancestor, jump to LCP
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

        // Sort ancestors by length (deepest first)
        ancestors.sort_unstable_by(|a, b| b.len.cmp(&a.len));

        let mut nodes = Vec::new();
        for anc in ancestors {
            let my_dir = get_bit_be(&path, anc.len);
            let sibling_dir = 1 - my_dir;

            // Calculate hypothetical sibling key
            let mut t_path = anc.path;
            set_bit_be(&mut t_path, anc.len, sibling_dir);
            mask_after_be(&mut t_path, anc.len + 1);
            let t_key = NodeKey { path: t_path, len: anc.len + 1 };

            // Find if sibling exists. We check strictly > t_key.
            // But we must ensure the found node actually is a descendant of the sibling prefix.
            let s_hash = self.seek_next_inclusive(&t_key)
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
    // UNIFIED VERIFICATION (Static)
    // ========================================================================

    pub fn verify(proof: &Proof, ns: Option<&[u8]>, k: &[u8], v: &[u8]) -> VerifyStatus {
        let target_path = compute_namespace_path(ns, k);
        let claimed_leaf_hash = concat_and_hash(k, v);

        // 1. Basic Integrity Check
        if !Self::verify_integrity(proof) {
            return VerifyStatus::Invalid;
        }

        // 2. Interpret result
        if proof.path == target_path {
            // Path matches exactly
            if proof.hash == claimed_leaf_hash {
                VerifyStatus::Included
            } else {
                VerifyStatus::Mismatch
            }
        } else {
            // Path does not match. Non-Existence.
            if prefix_match_be(&target_path, &proof.path, 0) {
                 VerifyStatus::NonExistence
            } else {
                 VerifyStatus::Invalid
            }
        }
    }

    pub fn verify_integrity(proof: &Proof) -> bool {
        if proof.root == ZERO_HASH {
            return proof.nodes.is_empty() && proof.hash == ZERO_HASH;
        }

        let calc = proof.nodes.iter().fold(proof.hash, |acc, node| {
            if node.direction == 0 {
                concat_and_hash(&node.hash, &acc)
            } else {
                concat_and_hash(&acc, &node.hash)
            }
        });
        calc == proof.root
    }

    // ========================================================================
    // INTERNAL HELPERS
    // ========================================================================
    fn insert_raw(&mut self, key: NodeKey, val: Hash) {
        let k = serialize_key(&key);
        kv_put(self.env, &k, &val);
    }

    fn remove_raw(&mut self, key: &NodeKey) {
        let k = serialize_key(key);
        kv_delete(self.env, &k);
    }

    fn exists_raw(&self, key: &NodeKey) -> bool {
        let k = serialize_key(key);
        self.env.txn.get_cf(&self.env.cf, k).unwrap().is_some()
    }

    fn ensure_node_exists(&mut self, key: NodeKey, dirty: &mut BTreeSet<NodeKey>) {
        if !self.exists_raw(&key) {
            self.insert_raw(key, ZERO_HASH);
            dirty.insert(key);
        }
    }

    fn ensure_split_points(&mut self, path: Path, dirty: &mut BTreeSet<NodeKey>) {
        let key = NodeKey { path, len: 256 };
        if let Some((n_key, _)) = self.seek_prev(&key) {
            if n_key.len == 256 {
                let (lcp_p, lcp_l) = lcp_be(&path, &n_key.path);
                self.ensure_node_exists(NodeKey { path: lcp_p, len: lcp_l }, dirty);
            }
        }
        if let Some((n_key, _)) = self.seek_next(&key) {
            if n_key.len == 256 {
                let (lcp_p, lcp_l) = lcp_be(&path, &n_key.path);
                self.ensure_node_exists(NodeKey { path: lcp_p, len: lcp_l }, dirty);
            }
        }
    }

    fn collect_dirty_ancestors(&self, target_path: Path, dirty: &mut BTreeSet<NodeKey>) {
        let mut cursor = NodeKey { path: target_path, len: 256 };
        loop {
            match self.seek_prev(&cursor) {
                None => break,
                Some((k, _)) => {
                    let is_same = k == cursor;
                    if prefix_match_be(&target_path, &k.path, k.len) {
                        dirty.insert(k);
                        if k.len > 0 { cursor = NodeKey{path: k.path, len: k.len - 1}; } else { break; }
                    } else {
                        let (lcp_p, lcp_l) = lcp_be(&target_path, &k.path);
                        let jump_key = NodeKey { path: lcp_p, len: lcp_l + 1 };
                        if jump_key < k {
                            cursor = jump_key;
                        } else {
                            if is_same {
                                if k.len > 0 { cursor = NodeKey{path: k.path, len: k.len - 1}; } else { break; }
                            } else {
                                cursor = k;
                            }
                        }
                    }
                }
            }
        }
    }

    fn rehash_and_prune(&mut self, dirty_nodes: BTreeSet<NodeKey>) {
        let mut sorted_nodes: Vec<NodeKey> = dirty_nodes.into_iter().collect();
        sorted_nodes.sort_unstable_by(|a, b| b.len.cmp(&a.len));

        for node in sorted_nodes {
            if node.len == 256 { continue; }

            // Re-check children
            let mut l_path = node.path;
            set_bit_be(&mut l_path, node.len, 0);
            mask_after_be(&mut l_path, node.len + 1);
            let l_key = NodeKey { path: l_path, len: node.len + 1 };

            let l_hash = self.seek_next_inclusive(&l_key)
                .filter(|(k, _)| prefix_match_be(&k.path, &l_path, node.len + 1))
                .map(|(_, h)| h).unwrap_or(ZERO_HASH);

            let mut r_path = node.path;
            set_bit_be(&mut r_path, node.len, 1);
            mask_after_be(&mut r_path, node.len + 1);
            let r_key = NodeKey { path: r_path, len: node.len + 1 };

            let r_hash = self.seek_next_inclusive(&r_key)
                .filter(|(k, _)| prefix_match_be(&k.path, &r_path, node.len + 1))
                .map(|(_, h)| h).unwrap_or(ZERO_HASH);

            if l_hash != ZERO_HASH && r_hash != ZERO_HASH {
                self.insert_raw(node, concat_and_hash(&l_hash, &r_hash));
            } else {
                self.remove_raw(&node);
            }
        }
    }

    // ========================================================================
    // ITERATOR WRAPPERS
    // ========================================================================

    /// Finds key <= target
    fn seek_prev(&self, key: &NodeKey) -> Option<(NodeKey, Hash)> {
        let k_bytes = serialize_key(key);
        let mut iter = self.env.txn.raw_iterator_cf(&self.env.cf);
        iter.seek_for_prev(k_bytes);

        if iter.valid() {
            let found_k = deserialize_key(iter.key().unwrap());
            let found_v: Hash = iter.value().unwrap().try_into().unwrap();
            Some((found_k, found_v))
        } else {
            None
        }
    }

    /// Finds key > target (Strictly Greater)
    fn seek_next(&self, key: &NodeKey) -> Option<(NodeKey, Hash)> {
        let k_bytes = serialize_key(key);
        let mut iter = self.env.txn.raw_iterator_cf(&self.env.cf);
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

    /// Finds key >= target (Inclusive)
    /// Used for finding if a child exists at a specific prefix
    fn seek_next_inclusive(&self, key: &NodeKey) -> Option<(NodeKey, Hash)> {
        let k_bytes = serialize_key(key);
        let mut iter = self.env.txn.raw_iterator_cf(&self.env.cf);
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
