use rustler::types::{Binary, OwnedBinary, LocalPid};
use rustler::{Encoder, Error, Env, Term, NifResult, ResourceArc, OwnedEnv, Atom};

//use std::collections::HashMap;
//use sha2::{Sha256, Digest};

use rust_rocksdb::{TransactionDB, MultiThreaded, TransactionDBOptions, Options,
    Cache, LruCacheOptions, BlockBasedOptions, DBCompressionType,
    ColumnFamilyDescriptor, AsColumnFamilyRef};

use std::path::Path;
use std::sync::Arc;
use std::ffi::{CStr, CString, c_void};
use std::ptr::NonNull;

mod atoms;

pub struct DbResource {
    pub db: TransactionDB<MultiThreaded>
}

pub struct CfResource {
    // Keep DB alive as long as the CF handle exists:
    db: ResourceArc<DbResource>,
    name: String,
    // Stable for the lifetime of the DB as long as you never drop the CF:
    handle: NonNull<rust_librocksdb_sys::rocksdb_column_family_handle_t>,
}

unsafe impl Send for CfResource {}
unsafe impl Sync for CfResource {}

impl AsColumnFamilyRef for CfResource {
    fn inner(&self) -> *mut rust_librocksdb_sys::rocksdb_column_family_handle_t {
        self.handle.as_ptr()
    }
}

fn on_load(env: Env, _: Term) -> bool {
    rustler::resource!(DbResource, env);
    rustler::resource!(CfResource, env);
    //rustler::resource!(TransactionResource, env);
    //rustler::resource!(IteratorResource, env);
    true
}

fn to_nif_err(err: rust_rocksdb::Error) -> Error {
    Error::Term(Box::new(err.to_string()))
}

#[rustler::nif]
fn test<'a>(env: Env<'a>) ->Result<Term<'a>, Error> {
    Ok((atoms::ok()).encode(env))
}

#[rustler::nif]
fn open_transaction_db<'a>(env: Env<'a>, path: String, cf_names: Vec<String>) -> NifResult<Term<'a>> {
    let mut lru_opts = LruCacheOptions::default();
    lru_opts.set_capacity(1 * 1024 * 1024 * 1024); //1GB
    lru_opts.set_num_shard_bits(8);
    let row_cache = Cache::new_lru_cache_opts(&lru_opts);

    let block_cache = Cache::new_lru_cache(1 * 1024 * 1024 * 1024); //1GB

    let mut db_opts = Options::default();
    db_opts.create_if_missing(true);
    db_opts.create_missing_column_families(true);
    db_opts.set_max_open_files(10000);
    db_opts.set_target_file_size_base(4 * 1024 * 1024 * 1024); // 4GB
    db_opts.set_target_file_size_multiplier(4);
    db_opts.set_max_total_wal_size(4 * 1024 * 1024 * 1024); // 4GB

    db_opts.enable_statistics();
    db_opts.set_statistics_level(rust_rocksdb::statistics::StatsLevel::All);
    db_opts.set_skip_stats_update_on_db_open(true);

    let mut txn_db_opts = TransactionDBOptions::default();
    txn_db_opts.set_default_lock_timeout(3000);
    txn_db_opts.set_txn_lock_timeout(3000);
    txn_db_opts.set_num_stripes(32);

    let mut cf_opts = Options::default();
    cf_opts.set_row_cache(&row_cache);

    let mut block_based_options = BlockBasedOptions::default();
    block_based_options.set_block_cache(&block_cache);
    block_based_options.set_cache_index_and_filter_blocks(true);
    block_based_options.set_pin_l0_filter_and_index_blocks_in_cache(true);
    cf_opts.set_block_based_table_factory(&block_based_options);

    let dict_bytes = 64 * 1024;
    cf_opts.set_compression_type(DBCompressionType::Zstd);
    cf_opts.set_compression_options(-14, 3, 0, dict_bytes);
    cf_opts.set_zstd_max_train_bytes(100 * dict_bytes);

    cf_opts.set_bottommost_compression_type(DBCompressionType::Zstd);
    cf_opts.set_bottommost_compression_options(-14, 6, 0, dict_bytes, true);
    cf_opts.set_bottommost_zstd_max_train_bytes(100 * dict_bytes, true);

    cf_opts.set_target_file_size_base(4 * 1024 * 1024 * 1024); // 4GB
    cf_opts.set_target_file_size_multiplier(4);
    cf_opts.set_max_total_wal_size(4 * 1024 * 1024 * 1024); // 4GB

    let cf_descriptors: Vec<_> = cf_names
        .iter()
        .map(|name| ColumnFamilyDescriptor::new(name.as_str(), cf_opts.clone()))
        .collect();


    match TransactionDB::open_cf_descriptors(&db_opts, &txn_db_opts, Path::new(&path), cf_descriptors) {
        Ok(db) => {
            let resource = ResourceArc::new(DbResource { db });

            let mut out = Vec::with_capacity(cf_names.len());
            for name in cf_names {
                let cf_arc = resource
                    .db
                    .cf_handle(&name)
                    .ok_or_else(|| Error::Term(Box::new(format!("unknown column family: {}", name))))?;
                let raw = cf_arc.inner();
                let handle = NonNull::new(raw).ok_or_else(|| Error::Term(Box::new("null CF handle")))?;
                let cf_res = ResourceArc::new(CfResource {
                    db: resource.clone(),
                    name: name.clone(),
                    handle,
                });
                out.push(cf_res);
            }

            Ok((atoms::ok(), resource, out).encode(env))
        }
        Err(e) => Err(to_nif_err(e)),
    }
}

#[rustler::nif]
fn property_value<'a>(env: Env<'a>, db_res: ResourceArc<DbResource>, key: String) -> NifResult<Term<'a>> {
    match db_res.db.property_value(&key) {    // Pass it as a reference
        Ok(Some(value)) => Ok((atoms::ok(), value).encode(env)),
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(e) => Err(to_nif_err(e)),
    }
}

#[rustler::nif]
fn get<'a>(env: Env<'a>, cf: ResourceArc<CfResource>, key: Binary) -> NifResult<Term<'a>> {
    match cf.db.db.get_cf(&*cf, key.as_slice()) {
        Ok(Some(value)) => Ok((atoms::ok(), value).encode(env)),
        Ok(None) => Ok((atoms::ok(), atoms::nil()).encode(env)),
        Err(e) => Err(to_nif_err(e)),
    }
}

#[rustler::nif]
fn put(cf: ResourceArc<CfResource>, key: Binary, value: Binary) -> NifResult<Atom> {
    cf.db.db
        .put_cf(&*cf, key.as_slice(), value.as_slice())
        .map(|_| atoms::ok())
        .map_err(to_nif_err)
}

#[rustler::nif]
fn delete(cf: ResourceArc<CfResource>, key: Binary) -> NifResult<Atom> {
    cf.db.db
        .delete_cf(&*cf, key.as_slice())
        .map(|_| atoms::ok())
        .map_err(to_nif_err)
}



rustler::init!("Elixir.RDB", load = on_load);
