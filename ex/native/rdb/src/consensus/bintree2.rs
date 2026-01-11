use sha2::{Digest, Sha256};
use std::cmp::{min, Ordering};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Bound;
use rayon::prelude::*;

pub type Hash = [u8; 32];
pub type Path = [u8; 32];
const ZERO_HASH: Hash = [0u8; 32];

// ============================================================================
// STRUCTS
// ============================================================================

/// The Universal Proof Struct.
///
/// - If `path` == sha256(key) and `hash` == sha256(key, value): It's an Inclusion Proof.
/// - If `path` == sha256(key) and `hash` != sha256(key, value): It's a Mismatch Proof.
/// - If `path` != sha256(key): It's a Non-Existence Proof (pointing to the closest ancestor).
#[derive(Debug, Clone)]
pub struct Proof {
    pub root: Hash,
    pub nodes: Vec<ProofNode>,
    pub path: Path, // The path of the leaf node actually found in the tree
    pub hash: Hash, // The hash of the leaf node actually found in the tree
}

/// A simplified proof node without length.
#[derive(Debug, Clone)]
pub struct ProofNode {
    pub hash: Hash,
    pub direction: u8,
    pub len: u16,
}

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
        // Big Endian sort: Path first, then Length
        match self.path.cmp(&other.path) {
            Ordering::Equal => self.len.cmp(&other.len),
            other => other,
        }
    }
}

#[derive(Debug)]
pub enum Op {
    Insert(Option<Vec<u8>>, Vec<u8>, Vec<u8>),
    Delete(Option<Vec<u8>>, Vec<u8>),
}

#[derive(Debug, PartialEq)]
pub enum VerifyStatus {
    Included,       // Key exists and Value matches
    Mismatch,       // Key exists but Value is different
    NonExistence,   // Key does not exist
    Invalid,        // The proof itself is mathematically invalid (bad root/chain)
}

#[inline]
pub fn compute_namespace_path(namespace: Option<&[u8]>, key: &[u8]) -> Path {
    let key_hash = sha256(key);

    let mut path = [0u8; 32];
    if let Some(ns) = namespace {
        let ns_hash = sha256(ns);
        path[0..8].copy_from_slice(&ns_hash[0..8]);
    }
    path[8..32].copy_from_slice(&key_hash[0..24]);
    path
}

#[inline]
fn node_hash(left: &Hash, right: &Hash) -> Hash {
    let mut hasher = Sha256::new();
    hasher.update(b"NODE"); // tag: internal node
    hasher.update(left);
    hasher.update(right);
    hasher.finalize().into()
}

#[inline]
fn leaf_hash(key: &[u8], value: &[u8]) -> Hash {
    let k_len = key.len() as u64;

    let mut hasher = Sha256::new();
    hasher.update(b"LEAF"); // tag: leaf node
    hasher.update(&k_len.to_be_bytes());
    hasher.update(key);
    hasher.update(value);
    hasher.finalize().into()
}

// ============================================================================
// BIT HELPERS (Optimized & Inlined)
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
    if val == 1 {
        data[byte_idx] |= 1 << bit_offset;
    } else {
        data[byte_idx] &= !(1 << bit_offset);
    }
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
    if byte_idx + 1 < 32 {
        data[(byte_idx + 1)..].fill(0);
    }
}

fn lcp_be(p1: &Path, p2: &Path) -> (Path, u16) {
    let mut len = 0;
    let mut byte_idx = 0;
    while byte_idx < 32 && p1[byte_idx] == p2[byte_idx] {
        len += 8;
        byte_idx += 1;
    }
    if byte_idx < 32 {
        for i in 0..8 {
            let idx = (byte_idx * 8) + i;
            if get_bit_be(p1, idx as u16) == get_bit_be(p2, idx as u16) {
                len += 1;
            } else {
                break;
            }
        }
    }
    let mut prefix = *p1;
    mask_after_be(&mut prefix, len);
    (prefix, len)
}

#[inline]
fn prefix_match_be(target: &Path, path: &Path, len: u16) -> bool {
    let full_bytes = (len >> 3) as usize;
    if target[..full_bytes] != path[..full_bytes] {
        return false;
    }
    let rem = len & 7;
    if rem > 0 {
        let mask = 0xFF << (8 - rem);
        if (target[full_bytes] & mask) != (path[full_bytes] & mask) {
            return false;
        }
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
// HUBT IMPLEMENTATION
// ============================================================================

pub struct Hubt2 {
    pub store: BTreeMap<NodeKey, Hash>,
}

impl Hubt2 {
    pub fn new() -> Self {
        Hubt2 { store: BTreeMap::new() }
    }

    pub fn root(&self) -> Hash {
        self.store.iter().next().map(|(_, h)| *h).unwrap_or(ZERO_HASH)
    }

    // --- BATCH UPDATE ---
    pub fn batch_update(&mut self, ops: Vec<Op>) {
        let mut prepared: Vec<(bool, Path, Hash)> = ops.into_par_iter().map(|op| {
            match op {
                Op::Insert(ns, k, v) => {
                    let path = compute_namespace_path(ns.as_deref(), &k);
                    (true, path, leaf_hash(&k, &v))
                },
                Op::Delete(ns, k) => {
                    let path = compute_namespace_path(ns.as_deref(), &k);
                    (false, path, ZERO_HASH)
                }
            }
        }).collect();
        prepared.sort_unstable_by(|a, b| a.1.cmp(&b.1));

        for (is_ins, p, _) in &prepared {
            if !*is_ins {
                self.store.remove(&NodeKey { path: *p, len: 256 });
            }
        }

        let mut inserts = Vec::with_capacity(prepared.len());
        for (is_ins, p, l) in &prepared {
            if *is_ins {
                self.store.insert(NodeKey { path: *p, len: 256 }, *l);
                inserts.push((*p, *l));
            }
        }

        for (p, l) in &inserts {
            self.ensure_split_points(*p, *l);
        }

        let mut dirty_set = BTreeSet::new();
        for (_, p, _) in &prepared {
            self.collect_dirty_ancestors(*p, &mut dirty_set);
        }

        self.rehash_and_prune(dirty_set);
    }

    fn ensure_split_points(&mut self, path: Path, leaf_hash: Hash) {
        let key = NodeKey { path, len: 256 };
        if let Some((n_key, n_hash)) = self.store.range(..key).next_back().map(|(k,v)| (*k, *v)) {
            if n_key.len == 256 { self.check_neighbor(path, leaf_hash, n_key.path, n_hash); }
        }
        if let Some((n_key, n_hash)) = self.store.range((Bound::Excluded(key), Bound::Unbounded)).next().map(|(k,v)| (*k, *v)) {
            if n_key.len == 256 { self.check_neighbor(path, leaf_hash, n_key.path, n_hash); }
        }
    }

    fn check_neighbor(&mut self, path: Path, leaf: Hash, n_path: Path, n_leaf: Hash) {
        let (lcp_path, len) = lcp_be(&path, &n_path);
        let dir = get_bit_be(&path, len);
        let temp_val = if dir == 0 {
            node_hash(&leaf, &n_leaf) // leaf is Left (0), n_leaf is Right (1)
        } else {
            node_hash(&n_leaf, &leaf) // leaf is Right (1), n_leaf is Left (0)
        };
        self.store.insert(NodeKey { path: lcp_path, len }, temp_val);
    }

    fn collect_dirty_ancestors(&self, target_path: Path, acc: &mut BTreeSet<NodeKey>) {
        let mut cursor = NodeKey { path: target_path, len: 256 };
        loop {
            match self.store.range(..cursor).next_back() {
                None => break,
                Some((k, _)) => {
                    if prefix_match_be(&target_path, &k.path, k.len) {
                        acc.insert(*k);
                        cursor = *k;
                    } else {
                        let (lcp_path, lcp_len) = lcp_be(&target_path, &k.path);
                        let jump_key = NodeKey { path: lcp_path, len: lcp_len + 1 };
                        cursor = if jump_key < *k { jump_key } else { *k };
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
            let l_hash = self.get_child_hash(node.path, node.len, 0);
            let r_hash = self.get_child_hash(node.path, node.len, 1);

            if l_hash != ZERO_HASH && r_hash != ZERO_HASH {
                self.store.insert(node, node_hash(&l_hash, &r_hash));
            } else {
                self.store.remove(&node);
            }
        }
    }

    fn get_child_hash(&self, p_path: Path, p_len: u16, dir: u8) -> Hash {
        let mut target_path = p_path;
        set_bit_be(&mut target_path, p_len, dir);
        mask_after_be(&mut target_path, p_len + 1);
        let target_key = NodeKey { path: target_path, len: p_len + 1 };

        if let Some((f_key, hash)) = self.store.range(target_key..).next() {
            if prefix_match_be(&f_key.path, &target_path, p_len + 1) {
                return *hash;
            }
        }
        ZERO_HASH
    }

    // ========================================================================
    // UNIFIED PROOF LOGIC
    // ========================================================================

    /// Generates a single Proof struct that covers Inclusion, Mismatch, or Non-Existence.
    ///
    /// The logic detects the state of `k` in the tree:
    /// 1. Finds the node matching `k` (or the longest matching prefix node).
    /// 2. Generates the merkle path to that node.
    /// 3. Returns the proof containing the found node's path and hash.
    pub fn prove(&self, ns: Option<Vec<u8>>, k: Vec<u8>) -> Proof {
        let target_path = compute_namespace_path(ns.as_deref(), &k);

        // Find the node that actually exists (Exact match OR Longest Prefix)
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

        Proof {
            root: self.root(),
            nodes: self.generate_proof_nodes(found_key.path, found_key.len),
            path: found_key.path,
            hash: found_hash,
        }
    }

    fn generate_proof_nodes(&self, path: Path, len: u16) -> Vec<ProofNode> {
        let mut ancestors = Vec::new();
        let mut cursor = NodeKey { path, len: 256 };

        loop {
            match self.store.range(..cursor).next_back() {
                None => break,
                Some((k, _)) => {
                    if prefix_match_be(&path, &k.path, k.len) {
                        if k.len < len { ancestors.push(*k); }
                        cursor = *k;
                    } else {
                        let (lcp_p, lcp_l) = lcp_be(&path, &k.path);
                        let jump = NodeKey{ path: lcp_p, len: lcp_l + 1 };
                        cursor = if jump < *k { jump } else { *k };
                    }
                }
            }
        }
        ancestors.sort_unstable_by(|a, b| b.len.cmp(&a.len));

        let mut nodes = Vec::new();
        for anc in ancestors {
            let my_dir = get_bit_be(&path, anc.len);
            let sibling_dir = 1 - my_dir;
            nodes.push(ProofNode {
                hash: self.get_child_hash(anc.path, anc.len, sibling_dir),
                direction: sibling_dir,
                len: anc.len,
            });
        }
        nodes
    }

    fn find_longest_prefix_node(&self, target: &Path) -> Option<(NodeKey, Hash)> {
        let s_key = NodeKey { path: *target, len: 256 };
        let prev = self.store.range(..=s_key).next_back();
        let next = self.store.range((Bound::Excluded(s_key), Bound::Unbounded)).next();

        match (prev, next) {
            (None, None) => None,
            (None, Some((k, h))) => Some((*k, *h)),
            (Some((k, h)), None) => Some((*k, *h)),
            (Some((pk, ph)), Some((nk, nh))) => {
                let (_, rp) = lcp_be(target, &pk.path);
                let (_, rn) = lcp_be(target, &nk.path);
                if min(rp, pk.len) >= min(rn, nk.len) { Some((*pk, *ph)) } else { Some((*nk, *nh)) }
            }
        }
    }

    // ========================================================================
    // UNIFIED VERIFICATION
    // ========================================================================

    /// Verifies the proof and determines the relationship between the Key, Value, and the Tree.
    pub fn verify(proof: &Proof, ns: Option<Vec<u8>>, k: Vec<u8>, v: Vec<u8>) -> VerifyStatus {
        let target_path = compute_namespace_path(ns.as_deref(), &k);
        let claimed_leaf_hash = leaf_hash(&k, &v);

        // 1. Basic Integrity Check: Does the proof path/hash actually hash up to the Root?
        if !Self::verify_integrity(proof) {
            return VerifyStatus::Invalid;
        }

        // 2. Interpret the result
        if proof.path == target_path {
            // Path matches exactly.
            if proof.hash == claimed_leaf_hash {
                return VerifyStatus::Included
            } else {
                return VerifyStatus::Mismatch
            }
        }

        // 1. Where do they diverge?
        let (_, div_len) = lcp_be(&target_path, &proof.path);

        // 2. Find the proof node that covers this divergence point.
        // If div_len is deeper than all proof nodes, it means the proof.path
        // leaf itself covers the divergence (it's a long leaf that "skips" the split).
        // If div_len matches a proof node, that node's sibling must be ZERO.

        for node in &proof.nodes {
            if node.len == div_len {
                // We found the split point in the proof.
                // The proof provides the SIBLING.
                // The sibling must be the direction 'target' wanted to go.
                let target_dir = get_bit_be(&target_path, div_len);

                // If the proof node provided IS the direction target wanted...
                if node.direction == target_dir {
                    // ...then that direction MUST be empty (ZERO_HASH)
                    if node.hash == ZERO_HASH {
                        return VerifyStatus::NonExistence;
                    } else {
                        // The tree is NOT empty where target should be.
                        // The server sent the wrong proof (should have sent a leaf from that subtree).
                        return VerifyStatus::Invalid;
                    }
                }
            }
        }

        // If we didn't find an explicit node at div_len, implies the
        // proof.path leaf extends PAST the divergence point.
        // Since proof.path exists and is a leaf, and it differs from target,
        // target implicitly does not exist.
        VerifyStatus::NonExistence
    }

    fn verify_integrity(proof: &Proof) -> bool {
        if proof.root == ZERO_HASH { return proof.nodes.is_empty() && proof.hash == ZERO_HASH; }

        let calc = proof.nodes.iter().fold(proof.hash, |acc, node| {
            if node.direction == 0 {
                node_hash(&node.hash, &acc)
            } else {
                node_hash(&acc, &node.hash)
            }
        });
        calc == proof.root
    }
}

// ============================================================================
// TESTS
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unified_proof_logic() {
        let mut hubt = Hubt2::new();
        let k1 = b"user:1".to_vec();
        let v1 = b"100".to_vec();

        // Insert Key 1
        hubt.batch_update(vec![Op::Insert(None, k1.clone(), v1.clone())]);

        // Case 1: Inclusion (Key exists, Value matches)
        let proof_inc = hubt.prove(None, k1.clone());
        assert_eq!(Hubt::verify(&proof_inc, None, k1.clone(), v1.clone()), VerifyStatus::Included);

        // Case 2: Mismatch (Key exists, Value differs)
        let v1_fake = b"999".to_vec();
        let proof_mis = hubt.prove(None, k1.clone()); // Same proof generation!
        assert_eq!(Hubt::verify(&proof_mis, None, k1.clone(), v1_fake), VerifyStatus::Mismatch);

        // Case 3: Non-Existence (Key does not exist)
        let k_missing = b"user:999".to_vec();
        let proof_non = hubt.prove(None, k_missing.clone());
        assert_eq!(Hubt::verify(&proof_non, None, k_missing, v1.clone()), VerifyStatus::NonExistence);
    }

    #[test]
    fn test_proof_integrity() {
        let mut hubt = Hubt2::new();
        // Insert multiple items to create depth
        hubt.batch_update(vec![
            Op::Insert(b"A".to_vec(), b"1".to_vec()),
            Op::Insert(b"B".to_vec(), b"2".to_vec()),
            Op::Insert(b"C".to_vec(), b"3".to_vec()),
        ]);

        let k = b"B".to_vec();
        let proof = hubt.prove(k);
        assert!(Hubt2::verify_integrity(&proof));
    }
}
