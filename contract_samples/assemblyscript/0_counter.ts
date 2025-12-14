import * as sdk from "./sdk";
import { b, b58 } from "./sdk";

export function init(): void {
  sdk.log("Init called during deployment of contract")
  sdk.kv_put("inited", "true")
}

export function get(): void {
  let cur_counter = sdk.bToI64(sdk.kv_get("the_counter"))
  sdk.ret(cur_counter)
}

export function increment(amount_ptr: i32): void {
  let amount = sdk.memory_read_string(amount_ptr)
  sdk.kv_increment("the_counter", amount)
  let incremented_counter = sdk.kv_increment("the_counter", roll_dice())
  sdk.ret(incremented_counter)
}

export function increment_another_counter(contract_ptr: i32): void {
  let contract = sdk.memory_read_bytes(contract_ptr)
  let incr_by = roll_dice()
  sdk.log(`Calling increment on ${b58(contract)} by ${incr_by}`)
  let other_counter = sdk.call(contract, "increment", [b(incr_by)])
  sdk.ret(other_counter)
}

//Current: VRF Stage 1 is used.
//Seed is signature of previous VRF by current validator.
//A malicious validator can do a withholding attack (not include a TX if the RNG is unfavorable)

//Coming Soon: VRF Stage 2 will be only attackable if 67% are malicious as it will use BLS Threshold /w DKG
export function roll_dice(): i64 {
  const val = Math.random(); // Returns 0.0 to 1.0
  return floor(val * 6) as i32 + 1; // Returns 1-6
}
