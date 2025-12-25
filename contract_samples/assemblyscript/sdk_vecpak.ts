export const TYPE_NULL: u8 = 0x00;
export const TYPE_TRUE: u8 = 0x01;
export const TYPE_FALSE: u8 = 0x02;
export const TYPE_INT: u8 = 0x03;
export const TYPE_BYTES: u8 = 0x05;
export const TYPE_LIST: u8 = 0x06;
export const TYPE_MAP: u8 = 0x07;

// --- 2. Helper Classes ---

export class DecodeRef {
  offset: i32 = 0;
}

class Field {
  constructor(
    public key: string,
    public keyBytes: Uint8Array,
    public valueBytes: Uint8Array,
  ) {}
}

// --- 3. Encoding Functions (Low Level) ---

export function encodeVarint(n: i64, out: Array<u8>): void {
  if (n == 0) {
    out.push(0);
    return;
  }

  const isNegative = n < 0;
  let value: u64 = isNegative ? <u64>-n : <u64>n;

  // Build magnitude in little-endian first
  const magBytes = new Array<u8>();
  while (value > 0) {
    magBytes.push(<u8>(value & 0xff));
    value = value >> 8;
  }
  // Reverse to get big-endian
  magBytes.reverse();

  const len = magBytes.length;
  // Header: sign bit (bit 7) | length (bits 0-6)
  const header = <u8>(((isNegative ? 1 : 0) << 7) | len);

  out.push(header);
  for (let i = 0; i < len; i++) {
    out.push(magBytes[i]);
  }
}

export function encodeU16(val: u16, out: Array<u8>): void {
  out.push(TYPE_INT);
  encodeVarint(<i64>val, out);
}

export function encodeI16(val: i16, out: Array<u8>): void {
  out.push(TYPE_INT);
  // Casting i16 to i64 preserves the sign automatically in AS
  encodeVarint(<i64>val, out);
}

export function encodeString(val: string, out: Array<u8>): void {
  out.push(TYPE_BYTES);

  const utf8 = String.UTF8.encode(val);
  encodeVarint(utf8.byteLength, out);

  // ArrayBuffer to Array<u8>
  const view = new DataView(utf8);
  for (let i = 0; i < utf8.byteLength; i++) {
    out.push(view.getUint8(i));
  }
}

export function encodeBytes(val: Uint8Array, out: Array<u8>): void {
  out.push(TYPE_BYTES);
  encodeVarint(val.length, out);

  for (let i = 0; i < val.length; i++) {
    out.push(val[i]);
  }
}

// --- 4. Decoding Functions (Low Level) ---

export function decodeVarint(data: Uint8Array, ref: DecodeRef): i64 {
  if (ref.offset >= data.length) throw new Error("EOF reading varint");

  const header = data[ref.offset];
  ref.offset++;

  if (header == 0) return 0;

  const signBit = header >> 7;
  // FIX: Cast the result to i32 immediately
  const length = <i32>(header & 0x7f);

  let mag: u64 = 0;

  // Now comparing i32 < i32, which is valid
  for (let i = 0; i < length; i++) {
    if (ref.offset >= data.length) throw new Error("EOF reading varint bytes");
    mag = (mag << 8) | (<u64>data[ref.offset]);
    ref.offset++;
  }

  return signBit == 1 ? -(<i64>mag) : <i64>mag;
}

export function decodeU16(data: Uint8Array, ref: DecodeRef): u16 {
  if (ref.offset >= data.length) throw new Error("EOF reading type");
  if (data[ref.offset] != TYPE_INT) throw new Error("Expected TYPE_INT");
  ref.offset++;
  return <u16>decodeVarint(data, ref);
}

export function decodeI16(data: Uint8Array, ref: DecodeRef): i16 {
  if (ref.offset >= data.length) throw new Error("EOF reading type");
  if (data[ref.offset] != TYPE_INT) throw new Error("Expected TYPE_INT");
  ref.offset++;
  // Cast the i64 result down to i16
  return <i16>decodeVarint(data, ref);
}

export function decodeString(data: Uint8Array, ref: DecodeRef): string {
  if (ref.offset >= data.length) throw new Error("EOF reading type");
  if (data[ref.offset] != TYPE_BYTES)
    throw new Error("Expected TYPE_BYTES for string");
  ref.offset++;

  const len = <i32>decodeVarint(data, ref);
  const start = ref.offset;
  const end = start + len;

  if (end > data.length) throw new Error("EOF reading string bytes");

  // Slice buffer
  const buffer = data.buffer.slice(
    data.byteOffset + start,
    data.byteOffset + end,
  );
  ref.offset += len;
  return String.UTF8.decode(buffer);
}

export function decodeBytes(data: Uint8Array, ref: DecodeRef): Uint8Array {
  if (ref.offset >= data.length) throw new Error("EOF reading type");
  if (data[ref.offset] != TYPE_BYTES)
    throw new Error("Expected TYPE_BYTES for Uint8Array");
  ref.offset++;

  const len = <i32>decodeVarint(data, ref);
  const start = ref.offset;
  const end = start + len;

  if (end > data.length) throw new Error("EOF reading bytes");

  // Create a copy for the result
  const result = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    result[i] = data[start + i];
  }

  ref.offset += len;
  return result;
}

// --- 5. High-Level Serializer (Sorting & Map Construction) ---

export class Serializer {
  private fields: Array<Field> = new Array<Field>();

  // Generic internal helper
  private addFieldRaw(key: string, valueBytes: Uint8Array): void {
    // We must encode the key to bytes to sort canonically
    const keyOut = new Array<u8>();
    encodeString(key, keyOut);

    const keyUint8 = new Uint8Array(keyOut.length);
    for (let i = 0; i < keyOut.length; i++) keyUint8[i] = keyOut[i];

    this.fields.push(new Field(key, keyUint8, valueBytes));
  }

  // Helper to convert Array<u8> -> Uint8Array
  private toUint8(arr: Array<u8>): Uint8Array {
    const res = new Uint8Array(arr.length);
    for (let i = 0; i < arr.length; i++) res[i] = arr[i];
    return res;
  }

  // --- Public API ---

  addU16(key: string, val: u16): void {
    const out = new Array<u8>();
    encodeU16(val, out);
    this.addFieldRaw(key, this.toUint8(out));
  }

  addI16(key: string, val: i16): void {
    const out = new Array<u8>();
    encodeI16(val, out);
    this.addFieldRaw(key, this.toUint8(out));
  }

  addString(key: string, val: string): void {
    const out = new Array<u8>();
    encodeString(val, out);
    this.addFieldRaw(key, this.toUint8(out));
  }

  addBytes(key: string, val: Uint8Array): void {
    const out = new Array<u8>();
    encodeBytes(val, out);
    this.addFieldRaw(key, this.toUint8(out));
  }

  finish(): Uint8Array {
    // 1. Canonical Sort: Compare raw key bytes
    this.fields.sort((a, b) => {
      const len = Math.min(a.keyBytes.length, b.keyBytes.length);
      for (let i = 0; i < len; i++) {
        if (a.keyBytes[i] != b.keyBytes[i]) {
          return a.keyBytes[i] - b.keyBytes[i];
        }
      }
      return a.keyBytes.length - b.keyBytes.length;
    });

    // 2. Construct final bytes
    const finalOut = new Array<u8>();

    // Map Header
    finalOut.push(TYPE_MAP);
    encodeVarint(this.fields.length, finalOut);

    for (let i = 0; i < this.fields.length; i++) {
      const f = this.fields[i];
      // Key
      for (let k = 0; k < f.keyBytes.length; k++) finalOut.push(f.keyBytes[k]);
      // Value
      for (let v = 0; v < f.valueBytes.length; v++)
        finalOut.push(f.valueBytes[v]);
    }

    return this.toUint8(finalOut);
  }
}

export class Deserializer {
  private ref: DecodeRef = new DecodeRef();
  private count: i64 = 0;
  private current: i64 = 0;

  constructor(public data: Uint8Array) {
    // Automatically parse the MAP header
    if (this.ref.offset >= data.length) throw new Error("Empty data");
    if (data[this.ref.offset] != TYPE_MAP)
      throw new Error("Expected Map Header");
    this.ref.offset++;

    // Read the number of fields
    this.count = decodeVarint(data, this.ref);
  }

  hasNext(): boolean {
    return this.current < this.count;
  }

  nextKey(): string {
    if (!this.hasNext()) throw new Error("No more fields");
    this.current++;
    // Keys are always encoded as strings in this format
    return decodeString(this.data, this.ref);
  }

  // --- Type Readers ---

  readU16(): u16 {
    return decodeU16(this.data, this.ref);
  }

  readI16(): i16 {
    return decodeI16(this.data, this.ref);
  }

  readBytes(): Uint8Array {
    return decodeBytes(this.data, this.ref);
  }

  // Allows you to ignore fields you don't know about (Forward Compatibility)
  skip(): void {
    if (this.ref.offset >= this.data.length) return;

    const type = this.data[this.ref.offset];

    // We don't increment offset here; the specific decode functions
    // inside the switch will handle the type byte + payload.

    // Note: We "peek" the type by reading the byte, but standard decode functions
    // (like decodeU16) usually consume the type byte.
    // However, for raw skipping, we need to handle the structure manually.

    // Logic: Read type byte -> Advance logic
    this.ref.offset++; // consume type header

    switch (type) {
      case TYPE_NULL:
      case TYPE_TRUE:
      case TYPE_FALSE:
        // No payload
        break;
      case TYPE_INT:
        // Just read the varint and ignore result
        decodeVarint(this.data, this.ref);
        break;
      case TYPE_BYTES: {
        const len = <i32>decodeVarint(this.data, this.ref);
        this.ref.offset += len; // Jump over bytes
        break;
      }
      // TODO: Recursive skip for TYPE_LIST and TYPE_MAP if needed.
      // For flat objects like Hero, this is not needed.
      default:
        throw new Error("Cannot skip unknown type: " + type.toString());
    }
  }
}
