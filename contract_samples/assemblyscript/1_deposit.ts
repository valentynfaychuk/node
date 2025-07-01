import * as sdk from "./sdk";
import { b, b58 } from "./sdk";

function vaultKey(symbol: string): Uint8Array {
  //return sdk.concat(b("vault:"), b58(sdk.account_caller()), b(`:${symbol}`))
  return b(`vault:${b58(sdk.account_caller())}:${symbol}`)
}

export function balance(symbol_ptr: i32): void {
  let symbol = sdk.memory_read_string(symbol_ptr);
  let balance = sdk.kv_get_bytes<u64>(vaultKey(symbol));
  sdk.return_value(balance);
}

export function deposit(): void {
  let symbol = sdk.attached_symbol()
  let amount = sdk.attached_amount()
  sdk.log(`deposit ${symbol} ${amount}`)

  let new_amount = sdk.kv_increment(vaultKey(symbol), amount);
  sdk.return_value(new_amount);
}

export function withdraw(symbol_ptr: i32, amount_ptr: i32): void {
  let symbol = sdk.memory_read_string(symbol_ptr);
  let amount = sdk.memory_read_string(amount_ptr);
  sdk.log(`withdraw ${symbol} ${amount}`)

  let amount_int = parseInt(amount, 10) as u64
  sdk.log(`int ${amount_int}`)
  let balance = sdk.kv_get_bytes<u64>(vaultKey(symbol))

  assert(amount_int > 0, "amount lte 0")
  assert(balance >= amount_int, "insufficent funds")

  sdk.kv_increment(vaultKey(symbol), `-${amount_int}`);
  let result = sdk.call(b("Coin"), "transfer", [sdk.account_caller(), b(amount), b(symbol)])

  sdk.return_value(`${balance - amount_int}`);
}

export function burn(symbol_ptr: i32, amount_ptr: i32): void {
  let symbol = sdk.memory_read_string(symbol_ptr);
  let amount = sdk.memory_read_string(amount_ptr);
  sdk.log(`burn ${symbol} ${amount}`)

  let burn_address = new Uint8Array(48) //zeros
  let result = sdk.call(b("Coin"), "transfer", [burn_address, b(amount), b(symbol)])
  sdk.return_value(result);
}
