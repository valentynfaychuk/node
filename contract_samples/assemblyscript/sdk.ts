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

const MAP = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
export function b58<T>(term: T): string {
  if (term instanceof Uint8Array) {
    return to_b58_1(term);
  } else {
    return to_b58_1(String.UTF8.encode(term));
  }
}

function to_b58_1(B: Uint8Array, A: string = MAP): string {
  let d = new Array<i32>();
  let s = "";

  for (let i = 0; i < B.length; i++) {
    let j = 0;
    let c: i32 = B[i];

    if (c == 0 && s.length == 0 && i != 0) s += "1";

    while (j < d.length || c != 0) {
      let n: i32 = j < d.length ? d[j] * 256 + c : c;
      c = n / 58 as i32;
      if (j < d.length) {
        d[j] = n % 58;
      } else {
        d.push(n % 58);
      }
      j++;
    }
  }

  for (let k = d.length - 1; k >= 0; k--) {
    s += A.charAt(d[k]);
  }

  return s;
}

export function b58_dec(term: string): Uint8Array | null {
  return from_b58_1(term);
}
function from_b58_1(S: string, A: string = MAP): Uint8Array | null {
  let d = new Array<i32>();
  let b = new Array<i32>();

  for (let i = 0; i < S.length; i++) {
    let j = 0;
    let c = A.indexOf(S.charAt(i));
    if (c < 0) return null;

    if (c == 0 && b.length == 0 && i != 0) b.push(0);

    while (j < d.length || c != 0) {
      let n = j < d.length ? d[j] * 58 + c : c;
      c = n >> 8;
      if (j < d.length) {
        d[j] = n & 0xff;
      } else {
        d.push(n & 0xff);
      }
      j++;
    }
  }

  for (let j = d.length - 1; j >= 0; j--) {
    b.push(d[j]);
  }

  let result = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) {
    result[i] = b[i] as u8;
  }

  return result;
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

export function b(str: string): Uint8Array {
  return Uint8Array.wrap(String.UTF8.encode(str, false));
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

export function exit(error: string): void {
  abort(error, "0", 0, 0);
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
  const size = load<i32>(termPtr);
  const dataPtr = termPtr + 4;

  if (size == -1) {
    exit("kv_get_key_does_not_exist");
  }

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
export function kv_get<T>(key: Uint8Array): T {
  return __kv_get<T>(changetype<i32>(key.dataStart), key.byteLength);
}

function __kv_get_or<T>(ptr: i32, len: i32, vdefault: T): T {
  const termPtr = import_kv_get(ptr, len);
  const size = load<i32>(termPtr);
  const dataPtr = termPtr + 4;

  if (size == -1) {
    return vdefault;
  }

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
export function kv_get_or<T>(key: Uint8Array, vdefault: T): T {
  return __kv_get_or<T>(changetype<i32>(key.dataStart), key.byteLength, vdefault);
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

export function call(contract: Uint8Array, func: string, args: Uint8Array[]): string {
  let funcBytes = String.UTF8.encode(func, false);
  let funcPtr   = changetype<i32>(funcBytes);

  let errorPtr = 30_000
  switch (args.length) {
    case 0:
      errorPtr = import_call_0(changetype<i32>(contract.dataStart), contract.byteLength, funcPtr, funcBytes.byteLength);
      break;
    case 1:
      errorPtr = import_call_1(changetype<i32>(contract.dataStart), contract.byteLength, funcPtr, funcBytes.byteLength,
        changetype<i32>(args[0].dataStart), args[0].byteLength);
      break;
    case 2:
      errorPtr = import_call_2(changetype<i32>(contract.dataStart), contract.byteLength, funcPtr, funcBytes.byteLength,
        changetype<i32>(args[0].dataStart), args[0].byteLength, changetype<i32>(args[1].dataStart), args[1].byteLength);
      break;
    case 3:
      errorPtr = import_call_3(changetype<i32>(contract.dataStart), contract.byteLength, funcPtr, funcBytes.byteLength,
        changetype<i32>(args[0].dataStart), args[0].byteLength, changetype<i32>(args[1].dataStart), args[1].byteLength,
        changetype<i32>(args[2].dataStart), args[2].byteLength);
      break;
    case 4:
      errorPtr = import_call_4(changetype<i32>(contract.dataStart), contract.byteLength, funcPtr, funcBytes.byteLength,
        changetype<i32>(args[0].dataStart), args[0].byteLength, changetype<i32>(args[1].dataStart), args[1].byteLength,
        changetype<i32>(args[2].dataStart), args[2].byteLength, changetype<i32>(args[3].dataStart), args[3].byteLength);
      break;
    default:
      abort("call_invalid_no_of_args");
  }

  return memory_read_string(errorPtr);
}

/*
export function kv_get<T,Y>(key: Y): T {
  let termPtr: i32;
  if (isString(key)) {
    let inner = String.UTF8.encode(key.toString(), false);
    termPtr = import_kv_get(changetype<i32>(inner), inner.byteLength);
  } else if (key instanceof Uint8Array) {
    termPtr = import_kv_get(changetype<i32>(key), key.byteLength);
  } else {
    abort("kv_get_invalid_type")
  }

  if (isInteger<Y>()) {
    let arr = memory_read_bytes(termPtr);
    return parseInt<Y>(String.UTF8.decodeUnsafe(termPtr+4, load<i32>(termPtr), false)) as Y
  } else if (idof<T>() == idof<i64>()) {
    return parseI64(String.UTF8.decodeUnsafe(termPtr+4, load<i32>(termPtr), false))
  } else if (idof<T>() == idof<string>()) {
    return String.UTF8.decodeUnsafe(termPtr+4, load<i32>(termPtr), false) as T
  } else if (idof<T>() == idof<Uint8Array>()) {
    return memory_read_bytes(termPtr);
  } else {
    abort("kv_get_invalid_return_type")
  }
  return null as T;
}
 */
/*
@external("env", "import_call")
declare function import_call(module_ptr: i32, module_len: i32,
  function_ptr: i32, function_len: i32, args_ptr: i32, args_len: i32): i32;
function call(line: string): i32 {
  let keyBytes = String.UTF8.encode(line);
  let keyPtr   = changetype<i32>(keyBytes);
  return import_call(keyPtr, keyBytes.byteLength, keyPtr, keyBytes.byteLength, keyPtr, keyBytes.byteLength)
}
*/
/*@external("env", "import_kv_get")
declare function import_kv_get(ptr: i32, len: i32): i32;
function kv_get<T,Y>(key: Y): T {
  let termPtr: i32;
  if (isString(key)) {
    let inner = String.UTF8.encode(key.toString(), false);
    termPtr = import_kv_get(changetype<i32>(inner), inner.byteLength);
  } else if (key instanceof Uint8Array) {
    termPtr = import_kv_get(changetype<i32>(key), key.byteLength);
  } else {
    abort("kv_get_invalid_type")
  }

  if (isInteger<Y>()) {
    let arr = memory_read_bytes(termPtr);
    return parseInt<Y>(String.UTF8.decodeUnsafe(termPtr+4, load<i32>(termPtr), false)) as Y
  }/* else if (idof<T>() == idof<i64>()) {
    return parseI64(String.UTF8.decodeUnsafe(termPtr+4, load<i32>(termPtr), false))
  } else if (idof<T>() == idof<string>()) {
    return String.UTF8.decodeUnsafe(termPtr+4, load<i32>(termPtr), false) as T
  } else if (idof<T>() == idof<Uint8Array>()) {
    return memory_read_bytes(termPtr);
  } else {
    abort("kv_get_invalid_return_type")
  }*/
//return null as T;
//}


/*
@external("env", "import_kv_increment")
declare function import_kv_increment(keyPtr: i32, keyLen: i32, amount: i64): i64;
function kv_increment(key: string, amount: i64): i64 {
  let keyBytes = String.UTF8.encode(key);
  let keyPtr   = changetype<i32>(keyBytes);
  let keyLen   = keyBytes.byteLength;

  return import_kv_increment(keyPtr, keyLen, amount);
}

@external("env", "import_kv_get")
declare function import_kv_get(keyPtr: i32, keyLen: i32): i32;
function kv_get(key: string): string {
  let keyBytes = String.UTF8.encode(key);
  let keyPtr   = changetype<i32>(keyBytes);
  let keyLen   = keyBytes.byteLength;

  const valPtr = import_kv_get(keyPtr, keyLen);
  if (!valPtr) {
    return "";
  }

  const valLen = load<u32>(valPtr);
  const valBytesPtr = valPtr + 4;
  //const valBytes = new Uint8Array(import_memory.buffer, valBytesPtr, valLen);
  //return String.UTF8.decode(valBytes.buffer);
  return "";
}

*/
