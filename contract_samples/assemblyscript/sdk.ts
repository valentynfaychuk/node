export function toHexString(bytes: Uint8Array): string {
  const hexChars = "0123456789ABCDEF";

  let tempU16 = new Array<u16>(bytes.length << 1);
  let j = 0;
  for (let i = 0; i < bytes.length; i++) {
    let b = bytes[i];
    tempU16[j++] = hexChars.charCodeAt(b >>> 4) as u16;
    tempU16[j++] = hexChars.charCodeAt(b & 0xF) as u16;
  }

  let tempI32 = new Array<i32>(tempU16.length);
  for (let k = 0; k < tempU16.length; k++) {
    tempI32[k] = tempU16[k]; // implicitly extends to i32
  }

  return String.fromCharCodes(tempI32);
}

function memory_read_bytes(ptr: i32): Uint8Array {
  let length = load<i32>(ptr);
  let result = new Uint8Array(length);
  memory.copy(changetype<usize>(result.buffer), ptr+4, length);
  return result;
}

export function base58_decode(input: string): Uint8Array {
  const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let bytes = new Array<u8>();
  for (let i = 0; i < input.length; i++) {
    let carry = ALPHABET.indexOf(input.charAt(i));
    if (carry < 0) throw new Error("Invalid Base58 char");
    for (let j = 0; j < bytes.length; j++) {
      let x = (bytes[j] as u32) * 58 + carry;
      bytes[j] = <u8>(x & 0xff);
      carry = x >> 8;
    }
    while (carry) {
      bytes.push(<u8>(carry & 0xff));
      carry >>= 8;
    }
  }
  let zeros = 0;
  while (zeros < input.length && input.charAt(zeros) == ALPHABET[0]) zeros++;
  let out = new Uint8Array(zeros + bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    out[zeros + i] = bytes[bytes.length - 1 - i];
  }
  return out;
}

export function utf8(str: string): Uint8Array {
  return Uint8Array.wrap(String.UTF8.encode(str, false))
}

export function concat(...chunks: Uint8Array[]): Uint8Array {
  let total = 0;
  for (let i = 0; i < chunks.length; i++) {
    total += chunks[i].length;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (let i = 0; i < chunks.length; i++) {
    out.set(chunks[i], offset);
    offset += chunks[i].length;
  }
  return out;
}

export function memory_read_string(ptr: i32): string {
  return String.UTF8.decodeUnsafe(ptr+4, load<i32>(ptr), false)
}

export function bin(str: string): ArrayBuffer {
  return String.UTF8.encode(str, false);
}

@external("env", "entry_signer_ptr")
declare const entry_signer_ptr: i32;
export function entry_signer(): Uint8Array { return memory_read_bytes(entry_signer_ptr) }

@external("env", "entry_prev_hash_ptr")
declare const entry_prev_hash_ptr: i32;
export function entry_prev_hash(): Uint8Array { return memory_read_bytes(entry_prev_hash_ptr) }

@external("env", "entry_vr_ptr")
declare const entry_vr_ptr: i32;
export function entry_vr(): Uint8Array { return memory_read_bytes(entry_vr_ptr) }

@external("env", "entry_dr_ptr")
declare const entry_dr_ptr: i32;
export function entry_dr(): Uint8Array { return memory_read_bytes(entry_dr_ptr) }

@external("env", "tx_signer_ptr")
declare const tx_signer_ptr: i32;
export function tx_signer(): Uint8Array { return memory_read_bytes(tx_signer_ptr) }

@external("env", "account_current_ptr")
declare const account_current_ptr: i32;
export function account_current(): Uint8Array { return memory_read_bytes(account_current_ptr) }
@external("env", "account_caller_ptr")
declare const account_caller_ptr: i32;
export function account_caller(): Uint8Array { return memory_read_bytes(account_caller_ptr) }
@external("env", "account_origin_ptr")
declare const account_origin_ptr: i32;
export function account_origin(): Uint8Array { return memory_read_bytes(account_origin_ptr) }

@external("env", "attached_symbol_ptr")
declare const attached_symbol_ptr: i32;
export function attached_symbol(): string { return memory_read_string(attached_symbol_ptr) }
@external("env", "attached_amount_ptr")
declare const attached_amount_ptr: i32;
export function attached_amount(): string { return memory_read_string(attached_amount_ptr) }

@external("env", "entry_slot")
declare const entry_slot: i64;
@external("env", "entry_prev_slot")
declare const entry_prev_slot: i64;
@external("env", "entry_height")
declare const entry_height: i64;
@external("env", "entry_epoch")
declare const entry_epoch: i64;
@external("env", "tx_nonce")
declare const tx_nonce: i64;

@external("env", "import_attach")
declare function import_attach(symbol_ptr: i32, symbol_len: i32, amount_ptr: i32, amount_len: i32): void;
export function attach(symbol: string, amount: string): void {
  let symbolBytes = String.UTF8.encode(symbol, false);
  let symbolPtr   = changetype<i32>(symbolBytes);
  let amountBytes = String.UTF8.encode(amount, false);
  let amountPtr   = changetype<i32>(amountBytes);
  import_attach(symbolPtr, symbolBytes.byteLength, amountPtr, amountBytes.byteLength)
}

@external("env", "import_log")
declare function import_log(ptr: i32, len: i32): void;
export function log(line: string): void {
  let keyBytes = String.UTF8.encode(line);
  let keyPtr   = changetype<i32>(keyBytes);
  import_log(keyPtr, keyBytes.byteLength)
}

@external("env", "import_return_value")
declare function import_return_value(ptr: i32, len: i32): void;
export function return_value<T>(ret: T): void {
  if (isInteger<T>() || isFloat<T>()) {
    let inner = String.UTF8.encode(ret.toString(), false);
    return import_return_value(changetype<i32>(inner), inner.byteLength);
  } else if (isString<T>()) {
    let inner = String.UTF8.encode(changetype<string>(ret), false);
    return import_return_value(changetype<i32>(inner), inner.byteLength);
  } else if (ret instanceof Uint8Array) {
    return import_return_value(changetype<i32>(ret), ret.byteLength);
  } else if (ret instanceof Array<u8>) {
    let data = Uint8Array.wrap(ret.buffer);
    return import_return_value(changetype<i32>(data), data.byteLength);
  } else {
    return import_return_value(0, 0);
  }
}

@external("env", "import_kv_increment")
declare function import_kv_increment(key_ptr: i32, key_len: i32, val_ptr: i32, val_len: i32): i32;
export function kv_increment<T>(key: T, val: string): string {
  if (isString<T>()) {
    let bkey = String.UTF8.encode(key, false);
    let bval = String.UTF8.encode(val, false);
    let rptr = import_kv_increment(changetype<i32>(bkey), bkey.byteLength, changetype<i32>(bval), bval.byteLength);
    return memory_read_string(rptr);
  } else if (key instanceof Uint8Array) {
    let bval = String.UTF8.encode(val, false);
    let rptr = import_kv_increment(changetype<i32>(key.dataStart), key.byteLength, changetype<i32>(bval), bval.byteLength);
    return memory_read_string(rptr);
  } else {
    abort("kv_increment_invalid_type")
  }
}

@external("env", "import_kv_get")
declare function import_kv_get(ptr: i32, len: i32): i32;
function __kv_get<T>(ptr: i32, len: i32): T {
  const termPtr = import_kv_get(ptr, len);
  const size    = load<i32>(termPtr);
  const dataPtr = termPtr + 4;

  if (isInteger<T>()) {
    // all int<32
    let s = String.UTF8.decodeUnsafe(dataPtr, size, false);
    return parseInt(s, 10) as T;
  } else if (idof<T>() == idof<i64>()) {
    let s = String.UTF8.decodeUnsafe(dataPtr, size, false);
    return parseI64(s) as unknown as T;
  } else if (idof<T>() == idof<string>()) {
    return String.UTF8.decodeUnsafe(dataPtr, size, false) as unknown as T;
  } else if (idof<T>() == idof<Uint8Array>()) {
    return memory_read_bytes(termPtr) as unknown as T;
  } else {
    abort("kv_get_invalid_return_type");
  }
}
export function kv_get<T>(key: string): T {
  const buf = String.UTF8.encode(key, false);
  return __kv_get<T>(changetype<i32>(buf), buf.byteLength);
}
export function kv_get_bytes<T>(key: Uint8Array): T {
  log(`${key.dataStart}`)
  return __kv_get<T>(changetype<i32>(key.dataStart), key.byteLength);
}

@external("env", "import_call_0")
declare function import_call_0(module_ptr: i32, module_len: i32, function_ptr: i32, function_len: i32): i32;
@external("env", "import_call_1")
declare function import_call_1(module_ptr: i32, module_len: i32, function_ptr: i32, function_len: i32,
  args_1_ptr: i32, args_1_len: i32): i32;
@external("env", "import_call_2")
declare function import_call_2(module_ptr: i32, module_len: i32, function_ptr: i32, function_len: i32,
  args_1_ptr: i32, args_1_len: i32, args_2_ptr: i32, args_2_len: i32): i32;
@external("env", "import_call_3")
declare function import_call_3(module_ptr: i32, module_len: i32, function_ptr: i32, function_len: i32,
  args_1_ptr: i32, args_1_len: i32, args_2_ptr: i32, args_2_len: i32, args_3_ptr: i32, args_3_len: i32): i32;
@external("env", "import_call_4")
declare function import_call_4(module_ptr: i32, module_len: i32, function_ptr: i32, function_len: i32,
  args_1_ptr: i32, args_1_len: i32, args_2_ptr: i32, args_2_len: i32, args_3_ptr: i32, args_3_len: i32, args_4_ptr: i32, args_4_len: i32): i32;

export function call(contract: ArrayBuffer, func: string, args: ArrayBuffer[]): string {
  let funcBytes = String.UTF8.encode(func, false);
  let funcPtr   = changetype<i32>(funcBytes);

  let errorPtr = 30_000
  switch (args.length) {
    case 0:
      errorPtr = import_call_0(changetype<i32>(contract), contract.byteLength, funcPtr, funcBytes.byteLength);
      break;
    case 1:
      errorPtr = import_call_1(changetype<i32>(contract), contract.byteLength, funcPtr, funcBytes.byteLength,
        changetype<i32>(args[0]), args[0].byteLength);
      break;
    case 2:
      errorPtr = import_call_2(changetype<i32>(contract), contract.byteLength, funcPtr, funcBytes.byteLength,
        changetype<i32>(args[0]), args[0].byteLength, changetype<i32>(args[1]), args[1].byteLength);
      break;
    case 3:
      errorPtr = import_call_3(changetype<i32>(contract), contract.byteLength, funcPtr, funcBytes.byteLength,
        changetype<i32>(args[0]), args[0].byteLength, changetype<i32>(args[1]), args[1].byteLength,
        changetype<i32>(args[2]), args[2].byteLength);
      break;
    case 4:
      errorPtr = import_call_4(changetype<i32>(contract), contract.byteLength, funcPtr, funcBytes.byteLength,
        changetype<i32>(args[0]), args[0].byteLength, changetype<i32>(args[1]), args[1].byteLength,
        changetype<i32>(args[2]), args[2].byteLength, changetype<i32>(args[3]), args[3].byteLength);
      break;
    default:
      abort("call_invalid_no_of_args");
  }

  return memory_read_string(errorPtr);
}
