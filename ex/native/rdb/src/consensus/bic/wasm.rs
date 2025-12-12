use crate::consensus::bic::protocol;
use crate::consensus::consensus_apply::{ApplyEnv};
use crate::consensus::consensus_kv::{kv_get, kv_get_prev, kv_get_next, kv_put, kv_exists, kv_delete, kv_set_bit, kv_increment, kv_get_prev_or_first};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};
use std::panic::panic_any;
use std::time::Instant;
use lazy_static::lazy_static;
use sha2::{Sha256, Digest};

use wasmer::{
    imports,
    wasmparser::{Parser, Payload, Operator},
    sys::{EngineBuilder, Features, CompilerConfig as _},
    AsStoreMut, Function, FunctionEnv, FunctionEnvMut, FunctionType, Global, Instance, Memory, MemoryType, Engine,
    MemoryView, Module, Pages, Store, Type, Value,
    RuntimeError
};
use wasmer_compiler_singlepass::Singlepass;
use wasmer_middlewares::{
    metering::{get_remaining_points, set_remaining_points, MeteringPoints},
    Metering,
};

use std::ffi::c_void;
#[derive(Clone)]
pub struct ApplyEnvPtr {
    pub ptr: *mut c_void,
}
unsafe impl Send for ApplyEnvPtr {}
unsafe impl Sync for ApplyEnvPtr {}
impl ApplyEnvPtr {
    pub unsafe fn as_mut<'a>(&self) -> &'a mut ApplyEnv<'a> {
        &mut *(self.ptr as *mut ApplyEnv<'a>)
    }
}

struct HostEnv {
    applyenv_ptr: ApplyEnvPtr,
    instance: Option<Instance>,
    memory: Memory,
    readonly: bool,
}

lazy_static! {
    static ref ARTIFACT_CACHE: Mutex<HashMap<Vec<u8>, Vec<u8>>> = Mutex::new(HashMap::new());
}

fn set_return_value(applyenv: &mut ApplyEnv, return_value: Vec<u8>) {
    if return_value.len() > protocol::WASM_MAX_PANIC_MSG_SIZE {
        panic_any("exec_return_value_too_large")
    }
    applyenv.caller_env.call_return_value = return_value
}

fn import_log_implementation(mut env: FunctionEnvMut<HostEnv>, ptr: i32, len: i32) {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };
    let len = len as usize;

    if len <= 0 {
        panic_any("exec_ptr_term_too_short")
    }
    if len > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    crate::consensus::consensus_kv::storage_budget_decr(applyenv, protocol::COST_PER_BYTE_HISTORICAL * len as i128);
    set_remaining_points(&mut store, &instance, applyenv.exec_left.max(0) as u64);

    let view = data.memory.clone().view(&store);

    let mut buffer = vec![0u8; len as usize];
    view.read(ptr as u64, &mut buffer).unwrap_or_else(|_| panic_any("exec_log_invalid_ptr"));
    log_line(applyenv, buffer.to_vec())
}

fn import_return_implementation(mut env: FunctionEnvMut<HostEnv>, ptr: i32, len: i32) -> Result<(), RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };
    let len = len as usize;

    if len > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    crate::consensus::consensus_kv::exec_budget_decr(applyenv, protocol::COST_PER_BYTE_HISTORICAL * len as i128);
    set_remaining_points(&mut store, &instance, applyenv.exec_left.max(0) as u64);

    let view = data.memory.clone().view(&store);

    let mut buffer = vec![0u8; len as usize];
    view.read(ptr as u64, &mut buffer).unwrap_or_else(|_| panic_any("exec_log_invalid_ptr"));
    set_return_value(applyenv, buffer.to_vec());
    Err(RuntimeError::new("EXIT_IMPORT_RETURN"))
}

fn build_prefixed_key(applyenv: &mut ApplyEnv, view: &MemoryView, ptr: i32, len: i32) -> Vec<u8> {
    let mut key = vec![0u8; len as usize];
    view.read(ptr as u64, &mut key).unwrap_or_else(|_| panic_any("exec_log_invalid_ptr"));

    crate::bcat(&[&b"account:"[..], &applyenv.caller_env.account_current, &b":storage:"[..], &key])
}

fn import_storage_kv_put_implementation(mut env: FunctionEnvMut<HostEnv>, key_ptr: i32, key_len: i32, val_ptr: i32, val_len: i32) -> Result<i32, RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };

    if key_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }
    if val_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    let view = data.memory.clone().view(&store);
    let key = build_prefixed_key(applyenv, &view, key_ptr, key_len);
    let mut value = vec![0u8; val_len as usize];
    view.read(val_ptr as u64, &mut value).unwrap_or_else(|_| panic_any("exec_log_invalid_ptr"));

    kv_put(applyenv, &key, &value);
    Ok(1)
}

fn import_storage_kv_increment_implementation(mut env: FunctionEnvMut<HostEnv>, key_ptr: i32, key_len: i32, val_ptr: i32, val_len: i32) -> Result<i32, RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };

    if key_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }
    if val_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    let view = data.memory.clone().view(&store);
    let key = build_prefixed_key(applyenv, &view, key_ptr, key_len);
    let mut value = vec![0u8; val_len as usize];
    view.read(val_ptr as u64, &mut value).unwrap_or_else(|_| panic_any("exec_log_invalid_ptr"));

    let value_int128 = std::str::from_utf8(&value).ok().and_then(|s| s.parse::<i128>().ok()).unwrap_or_else(|| panic_any("invalid_integer"));
    let new_value = kv_increment(applyenv, &key, value_int128).to_string();
    let new_value = new_value.as_bytes();

    view.write(10_000, &new_value.len().to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
    view.write(10_004, &new_value).unwrap_or_else(|_| panic_any("exec_memwrite"));

    Ok(10_000)
}

fn import_storage_kv_delete_implementation(mut env: FunctionEnvMut<HostEnv>, key_ptr: i32, key_len: i32) -> Result<i32, RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };

    if key_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    let view = data.memory.clone().view(&store);
    let key = build_prefixed_key(applyenv, &view, key_ptr, key_len);

    kv_delete(applyenv, &key);

    Ok(1)
}

fn import_storage_kv_get_implementation(mut env: FunctionEnvMut<HostEnv>, ptr: i32, len: i32) -> Result<i32, RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };

    if len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    let view = data.memory.clone().view(&store);
    let key = build_prefixed_key(applyenv, &view, ptr, len);
    match kv_get(applyenv, &key) {
        None => {
            view.write(10_000, &(-1i32).to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
        },
        Some(value) => {
            view.write(10_000, &value.len().to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
            view.write(10_004, &value).unwrap_or_else(|_| panic_any("exec_memwrite"));
        }
    }
    set_remaining_points(&mut store, &instance, applyenv.exec_left.max(0) as u64);
    Ok(10_000)
}

fn import_storage_kv_get_prev_implementation(mut env: FunctionEnvMut<HostEnv>, prefix_ptr: i32, prefix_len: i32, key_ptr: i32, key_len: i32) -> Result<i32, RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };

    if prefix_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }
    if key_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    let view = data.memory.clone().view(&store);
    let prefix = build_prefixed_key(applyenv, &view, prefix_ptr, prefix_len);
    let mut key = vec![0u8; key_len as usize];
    view.read(key_ptr as u64, &mut key).unwrap_or_else(|_| panic_any("exec_log_invalid_ptr"));

    match kv_get_prev(applyenv, &prefix, &key) {
        None => {
            view.write(10_000, &(-1i32).to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
        },
        Some((prev_key, value)) => {
            view.write(10_000, &prev_key.len().to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
            view.write(10_000 + 4, &prev_key).unwrap_or_else(|_| panic_any("exec_memwrite"));

            view.write(10_000 + 4 + prev_key.len() as u64, &value.len().to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
            view.write(10_000 + 4 + prev_key.len() as u64 + 4, &value).unwrap_or_else(|_| panic_any("exec_memwrite"));
        }
    }
    set_remaining_points(&mut store, &instance, applyenv.exec_left.max(0) as u64);
    Ok(10_000)
}

fn import_storage_kv_get_next_implementation(mut env: FunctionEnvMut<HostEnv>, prefix_ptr: i32, prefix_len: i32, key_ptr: i32, key_len: i32) -> Result<i32, RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };

    if prefix_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }
    if key_len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    let view = data.memory.clone().view(&store);
    let prefix = build_prefixed_key(applyenv, &view, prefix_ptr, prefix_len);
    let mut key = vec![0u8; key_len as usize];
    view.read(key_ptr as u64, &mut key).unwrap_or_else(|_| panic_any("exec_log_invalid_ptr"));

    match kv_get_next(applyenv, &prefix, &key) {
        None => {
            view.write(10_000, &(-1i32).to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
        },
        Some((next_key, value)) => {
            view.write(10_000, &next_key.len().to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
            view.write(10_000 + 4, &next_key).unwrap_or_else(|_| panic_any("exec_memwrite"));

            view.write(10_000 + 4 + next_key.len() as u64, &value.len().to_le_bytes()).unwrap_or_else(|_| panic_any("exec_memwrite"));
            view.write(10_000 + 4 + next_key.len() as u64 + 4, &value).unwrap_or_else(|_| panic_any("exec_memwrite"));
        }
    }
    set_remaining_points(&mut store, &instance, applyenv.exec_left.max(0) as u64);
    Ok(10_000)
}

fn import_storage_kv_exists_implementation(mut env: FunctionEnvMut<HostEnv>, ptr: i32, len: i32) -> Result<i32, RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };

    if len as usize > protocol::WASM_MAX_PTR_LEN {
        panic_any("exec_ptr_term_too_long")
    }

    let view = data.memory.clone().view(&store);
    let key = build_prefixed_key(applyenv, &view, ptr, len);

    let result = kv_exists(applyenv, &key);
    set_remaining_points(&mut store, &instance, applyenv.exec_left.max(0) as u64);
    match result {
        true => Ok(1),
        false => Ok(0)
    }
}

//AssemblyScript specific
fn as_read_string(view: &MemoryView, ptr: i32) -> String {
    if ptr == 0 { return "null".to_string(); }

    let ptr = ptr as u64;

    // 1. Read Length (stored at ptr - 4)
    // AssemblyScript stores length in BYTES (not characters) at offset -4
    let mut len_buf = [0u8; 4];
    if view.read(ptr - 4, &mut len_buf).is_err() {
        return "<invalid-ptr>".to_string();
    }
    let len_bytes = u32::from_le_bytes(len_buf) as u64;

    // 2. Read UTF-16 Bytes
    let mut str_buf = vec![0u8; len_bytes as usize];
    if view.read(ptr, &mut str_buf).is_err() {
        return "<invalid-mem>".to_string();
    }

    // 3. Convert [u8] -> [u16] -> String
    let u16_vec: Vec<u16> = str_buf
        .chunks_exact(2)
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
        .collect();

    String::from_utf16_lossy(&u16_vec)
}

fn as_abort_implementation(mut env: FunctionEnvMut<HostEnv>, msg_ptr: i32, filename_ptr: i32, line: i32, column: i32) -> Result<(), RuntimeError> {
    let (data, mut store) = env.data_and_store_mut();
    let instance = data.instance.clone().unwrap_or_else(|| panic_any("exec_instance_not_injected"));
    let view = data.memory.clone().view(&store);
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };

    //set_return_value(applyenv, b"as_abort".to_vec());

    let msg = as_read_string(&view, msg_ptr);
    let filename = as_read_string(&view, filename_ptr);

    let full_error_msg = format!("as_abort: '{}' at {}:{}:{}",
        msg, filename, line, column
    );

    crate::consensus::consensus_kv::exec_budget_decr(applyenv, protocol::COST_PER_BYTE_HISTORICAL * full_error_msg.len() as i128);
    set_remaining_points(&mut store, &instance, applyenv.exec_left.max(0) as u64);

    log_line(applyenv, full_error_msg.as_bytes().to_vec());

    //TODO: is this OK?
    panic_any("as_abort");
    Ok(())
    //Err(RuntimeError::new("as_abort"))
}

fn log_line(applyenv: &mut ApplyEnv, line: Vec<u8>) {
    let len = line.len();
    if len > protocol::LOG_MSG_SIZE {
        panic_any("exec_log_msg_size_exceeded")
    }
    if (applyenv.logs_size.saturating_add(len)) > protocol::LOG_TOTAL_SIZE {
        panic_any("exec_logs_total_size_exceeded")
    }
    if applyenv.logs.len() > protocol::LOG_TOTAL_ELEMENTS {
        panic_any("exec_logs_total_elements_exceeded")
    }

    applyenv.logs.push(line);
    applyenv.logs_size += len
}

pub fn check_module_limits(wasm_bytes: &[u8]) -> Result<(), String> {
    if wasm_bytes.len() > protocol::WASM_MAX_BINARY_SIZE {
        return Err("wasmparser_binary_size_exceeds_limit".to_string());
    }

    for payload in Parser::new(0).parse_all(wasm_bytes) {
        match payload.map_err(|e| e.to_string())? {
            Payload::FunctionSection(reader) => {
                let count = reader.count();
                if count > protocol::WASM_MAX_FUNCTIONS {
                    return Err("wasmparser_function_count_exceeds_limit".to_string());
                }
            },
            Payload::GlobalSection(reader) => {
                let count = reader.count();
                if count > protocol::WASM_MAX_GLOBALS {
                    return Err("wasmparser_global_count_exceeds_limit".to_string());
                }
            },
            Payload::ExportSection(reader) => {
                let count = reader.count();
                if count > protocol::WASM_MAX_EXPORTS {
                    return Err("wasmparser_export_count_exceeds_limit".to_string());
                }
            },
            Payload::ImportSection(reader) => {
                let count = reader.count();
                if count > protocol::WASM_MAX_IMPORTS {
                    return Err("wasmparser_import_count_exceeds_limit".to_string());
                }
            },
            Payload::CodeSectionStart { count, .. } => {
                if count > protocol::WASM_MAX_FUNCTIONS {
                    return Err("wasmparser_code_body_count_exceeds_limit".to_string());
                }
            },
            Payload::DataSection(reader) => {
                for data in reader {
                    let d = data.map_err(|e| e.to_string())?;
                    if let wasmer::wasmparser::DataKind::Active { offset_expr, .. } = d.kind {
                         let mut r = offset_expr.get_binary_reader();
                         if let Ok(wasmer::wasmparser::Operator::I32Const { value }) = r.read_operator() {
                             if value >= 0 && value < 65536 {
                                 return Err("wasmparser_first_65536_bytes_not_reserved".to_string());
                             }
                         }
                    }
                }
            }
            _ => {}
        }
    }
    Ok(())
}

pub fn validate_contract(env: &mut ApplyEnv, wasm_bytes: &[u8]) {
    if let Err(e) = check_module_limits(wasm_bytes) {
        panic_any(e)
    }

    let engine = make_engine(env.exec_left.max(0) as u64);
    let mut store = Store::new(engine);

    let module = Module::new(&store, wasm_bytes).unwrap_or_else(|_| panic_any("exec_invalid_module"));

    setup_wasm_instance(env, &module, &mut store, true, &[]);
}

fn cost_function(operator: &Operator) -> u64 {
    match operator {
        Operator::Loop { .. }
        | Operator::Block { .. }
        | Operator::End { .. }
        | Operator::Br { .. } => 1,

        Operator::I32Load { .. }
        | Operator::I64Load { .. }
        | Operator::I32Store { .. }
        | Operator::I64Store { .. } => 3,

        Operator::F32Load { .. }
        | Operator::F64Load { .. }
        | Operator::F32Store { .. }
        | Operator::F64Store { .. } => 10,

        Operator::Call { .. }
        | Operator::CallIndirect { .. } => 10,

        //TODO: middleware based on bytes copied
        Operator::MemoryCopy { .. }
        | Operator::MemoryFill { .. } => 1000,
        Operator::MemoryGrow { .. } => 2000,

        Operator::If { .. }
        | Operator::Else { .. }
        | Operator::BrIf { .. }
        | Operator::Return { .. }
        | Operator::Unreachable { .. } => 2,
        _ => 2,
    }
}

fn make_engine(exec_remaining: u64) -> Engine {
    let metering = Arc::new(Metering::new(exec_remaining, cost_function));

    let mut compiler = Singlepass::default();
    compiler.canonicalize_nans(true);
    compiler.push_middleware(metering);

    let mut features = Features::new();
    features.threads(false);
    features.reference_types(false);
    features.simd(false);
    features.multi_value(false);
    features.tail_call(false);
    features.module_linking(false);
    features.memory64(false);
    features.bulk_memory(true);

    EngineBuilder::new(compiler)
        .set_features(Some(features))
        .into()
}

pub fn setup_wasm_instance(env: &mut ApplyEnv, module: &Module, store: &mut Store, readonly: bool, function_args: &[Vec<u8>]) -> (Instance, Vec<Value>) {
    // Setup Memory
    let memory = Memory::new(store, MemoryType::new(Pages(2), Some(Pages(30)), false)).unwrap_or_else(|_| panic_any("exec_memory_alloc"));

    let mut wasm_arg_ptrs: Vec<Value> = Vec::new();
    {
        let view = memory.view(store);
        inject_env_data(&view, env);
        let mut current_offset: u64 = 10_000;
        for arg_bytes in function_args {
            // Write the length + bytes
            let len = arg_bytes.len() as i32;
            view.write(current_offset, &len.to_le_bytes()).unwrap_or_else(|_| panic_any("exec_arg_len_write"));
            view.write(current_offset + 4, arg_bytes).unwrap_or_else(|_| panic_any("exec_arg_write"));
            // Save the POINTER (i32) to pass to the function call later
            wasm_arg_ptrs.push(Value::I32(current_offset as i32));
            // Advance offset
            current_offset += 4 + (arg_bytes.len() as u64);
        }
    }

    // Setup Host Environment
    let apply_ptr = env as *mut ApplyEnv as *mut c_void;
    let applyenv_ptr = ApplyEnvPtr { ptr: apply_ptr };

    let host_env_data = HostEnv {
        memory: memory.clone(),
        instance: None,
        readonly,
        applyenv_ptr,
    };

    let host_env = FunctionEnv::new(store, host_env_data);

    // Imports
    let import_object = imports! {
        "env" => {
            "memory" => memory,
            "import_log" => Function::new_typed_with_env(store, &host_env, import_log_implementation),
            "import_return" => Function::new_typed_with_env(store, &host_env, import_return_implementation),

            //Storage
            "import_kv_put" => Function::new_typed_with_env(store, &host_env, import_storage_kv_put_implementation),
            "import_kv_increment" => Function::new_typed_with_env(store, &host_env, import_storage_kv_increment_implementation),
            "import_kv_delete" => Function::new_typed_with_env(store, &host_env, import_storage_kv_delete_implementation),

            "import_kv_get" => Function::new_typed_with_env(store, &host_env, import_storage_kv_get_implementation),
            "import_kv_exists" => Function::new_typed_with_env(store, &host_env, import_storage_kv_exists_implementation),
            "import_kv_get_prev" => Function::new_typed_with_env(store, &host_env, import_storage_kv_get_prev_implementation),
            "import_kv_get_next" => Function::new_typed_with_env(store, &host_env, import_storage_kv_get_next_implementation),


/*
            "import_attach" => Function::new_typed_with_env(&mut store, &host_env, import_attach_implementation),


            "import_call_0" => Function::new_typed_with_env(&mut store, &host_env, import_call_0_implementation),
            "import_call_1" => Function::new_typed_with_env(&mut store, &host_env, import_call_1_implementation),
            "import_call_2" => Function::new_typed_with_env(&mut store, &host_env, import_call_2_implementation),
            "import_call_3" => Function::new_typed_with_env(&mut store, &host_env, import_call_3_implementation),
            "import_call_4" => Function::new_typed_with_env(&mut store, &host_env, import_call_4_implementation),

            //storage
            "import_kv_clear" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_clear_implementation),

 */

            //AssemblyScript specific
            "abort" => Function::new_typed_with_env(store, &host_env, as_abort_implementation),
            //"seed" => Global::new(&mut store, Value::F64(mapenv.map_get(atoms::seedf64())?.decode::<f64>()?)),
        }
    };

    // Create Instance
    let instance = Instance::new(store, module, &import_object).unwrap_or_else(|e| {
        log_line(env, e.to_string().into_bytes());
        panic_any("exec_instance")
    });
    host_env.as_mut(store).instance = Some(instance.clone());
    (instance, wasm_arg_ptrs)
}

fn inject_env_data(view: &MemoryView, env: &ApplyEnv) {
    let mut w = |offset: u64, data: &[u8]| {
        view.write(offset, data).unwrap_or_else(|_| panic_any("exec_init_memwrite"))
    };

    //Reserve first 1024 bytes
    //Reserve first page 65536 bytes
    w(1_100, &env.caller_env.seed.len().to_le_bytes());
    w(1_104, &env.caller_env.seed);

    // Entry
    w(2_000, &env.caller_env.entry_slot.to_le_bytes());
    w(2_010, &env.caller_env.entry_height.to_le_bytes());
    w(2_020, &env.caller_env.entry_epoch.to_le_bytes());
    //
    w(2_100, &env.caller_env.entry_signer.len().to_le_bytes());
    w(2_104, &env.caller_env.entry_signer);
    w(2_200, &env.caller_env.entry_prev_hash.len().to_le_bytes());
    w(2_204, &env.caller_env.entry_prev_hash);
    w(2_300, &env.caller_env.entry_vr.len().to_le_bytes());
    w(2_304, &env.caller_env.entry_vr);
    w(2_400, &env.caller_env.entry_dr.len().to_le_bytes());
    w(2_404, &env.caller_env.entry_dr);

    // TX
    w(3_000, &env.caller_env.tx_nonce.to_le_bytes());
    //
    w(3_100, &env.caller_env.tx_signer.len().to_le_bytes());
    w(3_104, &env.caller_env.tx_signer);

    // Accounts
    w(4_000, &env.caller_env.account_current.len().to_le_bytes());
    w(4_004, &env.caller_env.account_current);
    w(4_100, &env.caller_env.account_caller.len().to_le_bytes());
    w(4_104, &env.caller_env.account_caller);
    w(4_200, &env.caller_env.account_origin.len().to_le_bytes());
    w(4_204, &env.caller_env.account_origin);

    // Assets
    w(5_000, &env.caller_env.attached_symbol.len().to_le_bytes());
    w(5_004, &env.caller_env.attached_symbol);
    w(5_100, &env.caller_env.attached_amount.len().to_le_bytes());
    w(5_104, &env.caller_env.attached_amount);
}

pub fn call_contract(env: &mut ApplyEnv, wasm_bytes: &[u8], function_name: String, function_args: Vec<Vec<u8>>) -> Vec<u8> {
    env.caller_env.call_return_value = Vec::new();

    let engine = make_engine(env.exec_left.max(0) as u64);
    let mut store = Store::new(engine);

    // Load Module (From Cache or Compile)
    let wasm_hash = Sha256::digest(wasm_bytes).to_vec();
    let module = {
        let mut cache = ARTIFACT_CACHE.lock().unwrap();

        //TODO: fix this to be more deterministic, as caches are node local
        if let Some(artifact_bytes) = cache.get(&wasm_hash) {
            // FAST PATH: Deserialize from cache
            unsafe { Module::deserialize(&store, artifact_bytes) }
                .unwrap_or_else(|_| panic_any("exec_deserialize_err"))
        } else {
            // SLOW PATH: Compile from scratch
            let new_module = Module::new(&store, wasm_bytes).unwrap_or_else(|_| panic_any("exec_invalid_module"));

            // Serialize and Cache
            let artifact = new_module.serialize().unwrap_or_else(|_| panic_any("exec_serialize_err"));
            cache.insert(wasm_hash, artifact.to_vec());

            new_module
        }
    };

    let (instance, wasm_args) = setup_wasm_instance(env, &module, &mut store, false, &function_args);

    let entry_to_call = instance.exports.get_function(&function_name).unwrap_or_else(|e| {
        log_line(env, e.to_string().into_bytes());
        panic_any("exec_function_not_found")
    });
    let start = Instant::now();
    let call_result = entry_to_call.call(&mut store, &wasm_args);
    let duration = start.elapsed();
    println!("call result {} {:?}", duration.as_millis(), call_result);

    let remaining = match get_remaining_points(&mut store, &instance) {
        MeteringPoints::Remaining(v) => v,
        MeteringPoints::Exhausted => {
            env.exec_left = 0;
            panic_any("exec_insufficient_exec_budget")
        },
    };
    env.exec_left = remaining as i128;

    match call_result {
        Ok(_) => env.caller_env.call_return_value.clone(),
        Err(ref e) if e.message() == "EXIT_IMPORT_RETURN" => env.caller_env.call_return_value.clone(),
        Err(err) => {
            log_line(env, err.message().into_bytes());
            panic_any("exec_error");
        }
    }
}
