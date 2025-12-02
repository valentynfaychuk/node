use crate::consensus::bic::protocol;
use crate::consensus::consensus_apply::{ApplyEnv};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};
use std::panic::panic_any;


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
    memory: Memory,
    readonly: bool,
    applyenv_ptr: ApplyEnvPtr,

    //error: Option<Vec<u8>>,
    //return_value: Option<Vec<u8>>,
    //logs: Vec<Vec<u8>>,
    //current_account: Vec<u8>,
    //instance: Option<Arc<Instance>>,

    //attached_symbol: Vec<u8>,
    //attached_amount: Vec<u8>,
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

fn import_log_implementation(mut env: FunctionEnvMut<HostEnv>, ptr: i32, len: i32) {
    let (data, store) = env.data_and_store_mut();
    let view = data.memory.clone().view(&store);
    let applyenv = unsafe { data.applyenv_ptr.as_mut() };
    let len = len as usize;

    if len > protocol::WASM_MAX_PTR_LEN {
        panic_any("wasm_ptr_term_too_long")
    }
    if len > protocol::LOG_MSG_SIZE {
        panic_any("wasm_log_msg_size_exceeded")
    }
    if (applyenv.logs_size.saturating_add(len)) > protocol::LOG_TOTAL_SIZE {
        panic_any("wasm_logs_total_size_exceeded")
    }

    let mut buffer = vec![0u8; len as usize];
    if view.read(ptr as u64, &mut buffer).is_ok() {
        applyenv.logs.push(buffer.to_vec());
        applyenv.logs_size += len
    } else {
        panic_any("wasm_log_invalid_ptr")
    }
}

pub fn check_module_limits(wasm_bytes: &[u8]) -> Result<(), String> {
    if wasm_bytes.len() > protocol::WASM_MAX_BINARY_SIZE {
        return Err("binary_size_exceeds_limit".to_string());
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

fn validate_contract(mut env: ApplyEnv, wasm_bytes: &[u8]) {
    if let Err(e) = check_module_limits(wasm_bytes) {
        panic_any(e)
    }

    let metering = Arc::new(Metering::new(env.exec_left.max(0) as u64, cost_function));
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

    //required for modern compilers to WASM
    features.bulk_memory(true);

    let engine = EngineBuilder::new(compiler).set_features(Some(features));
    let mut store = Store::new(engine);
    let module = Module::new(&store, wasm_bytes).unwrap_or_else(|_| panic_any("wasm_invalid_module"));

    let memory = Memory::new(&mut store, MemoryType::new(Pages(2), Some(Pages(20)), false)).unwrap_or_else(|_| panic_any("wasm_memory_alloc"));
    let view = memory.view(&mut store);

    //Reserve first 1024 bytes
    //Reserve first page 65536 bytes
    view.write(1_100, &env.caller_env.seed.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(1_104, &env.caller_env.seed).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));

    // Entry
    view.write(2_000, &env.caller_env.entry_slot.to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_010, &env.caller_env.entry_height.to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_020, &env.caller_env.entry_epoch.to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    //
    view.write(2_100, &env.caller_env.entry_signer.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_104, &env.caller_env.entry_signer).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_200, &env.caller_env.entry_prev_hash.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_204, &env.caller_env.entry_prev_hash).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_300, &env.caller_env.entry_vr.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_304, &env.caller_env.entry_vr).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_400, &env.caller_env.entry_dr.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(2_404, &env.caller_env.entry_dr).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));

    // TX
    view.write(3_000, &env.caller_env.tx_nonce.to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    //
    view.write(3_100, &env.caller_env.tx_signer.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(3_104, &env.caller_env.tx_signer).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    //
    view.write(4_000, &env.caller_env.account_current.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(4_004, &env.caller_env.account_current).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(4_100, &env.caller_env.account_caller.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(4_104, &env.caller_env.account_caller).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(4_200, &env.caller_env.account_origin.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(4_204, &env.caller_env.account_origin).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    //
    view.write(5_000, &env.caller_env.attached_symbol.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(5_004, &env.caller_env.attached_symbol).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(5_100, &env.caller_env.attached_amount.len().to_le_bytes()).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));
    view.write(5_104, &env.caller_env.attached_amount).unwrap_or_else(|_| panic_any("wasm_init_memwrite"));

    let apply_ptr = &mut env as *mut ApplyEnv as *mut c_void;
    let applyenv_ptr = ApplyEnvPtr { ptr: apply_ptr };

    let host_env = FunctionEnv::new(&mut store, HostEnv {
        memory: memory.clone(), readonly: true, applyenv_ptr: applyenv_ptr,
    });

    let import_object = imports! {
        "env" => {
            "memory" => memory,
            "import_log" => Function::new_typed_with_env(&mut store, &host_env, import_log_implementation),
/*
            "import_return" => Function::new_typed_with_env(&mut store, &host_env, import_return_implementation),


            "import_attach" => Function::new_typed_with_env(&mut store, &host_env, import_attach_implementation),


            "import_call_0" => Function::new_typed_with_env(&mut store, &host_env, import_call_0_implementation),
            "import_call_1" => Function::new_typed_with_env(&mut store, &host_env, import_call_1_implementation),
            "import_call_2" => Function::new_typed_with_env(&mut store, &host_env, import_call_2_implementation),
            "import_call_3" => Function::new_typed_with_env(&mut store, &host_env, import_call_3_implementation),
            "import_call_4" => Function::new_typed_with_env(&mut store, &host_env, import_call_4_implementation),

            //storage
            "import_kv_put" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_put_implementation),
            "import_kv_increment" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_increment_implementation),
            "import_kv_delete" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_delete_implementation),
            "import_kv_clear" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_clear_implementation),

            "import_kv_get" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_get_implementation),
            "import_kv_exists" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_exists_implementation),
            "import_kv_get_prev" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_get_prev_implementation),
            "import_kv_get_next" => Function::new_typed_with_env(&mut store, &host_env, import_storage_kv_get_next_implementation),
 */
            //"import_kv_put_int" => Function::new_typed(&mut store, || println!("called_kv_put_in_rust")),
            //"import_kv_get_prefix" => Function::new_typed(&mut store, || println!("called_kv_get_in_rust")),

            //AssemblyScript specific
            //"abort" => Function::new_typed_with_env(&mut store, &host_env, abort_implementation),
            //"seed" => Global::new(&mut store, Value::F64(mapenv.map_get(atoms::seedf64())?.decode::<f64>()?)),
        }
    };

    let instance = Instance::new(&mut store, &module, &import_object).unwrap_or_else(|_| panic_any("wasm_instance"));
}
