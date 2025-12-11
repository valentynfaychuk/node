import * as sdk from "./sdk";
import { b, b58 } from "./sdk";

export function get(): void {
  sdk.log(`get called`)
  if (sdk.kv_exists(b("the_counter"))) {
    sdk.log("exists")
  }
  let cur_counter = sdk.kv_get_or<i64>(b("the_counter"), 0)
  sdk.kv_put(b("the_counter"), b("1"))
  //let new_counter = sdk.kv_increment(b("the_counter"), "1")
  assert(cur_counter < 10, "counter is over 10")
  sdk.ret(cur_counter)
}

export function increment(amount_ptr: i32): void {
  let amount = sdk.memory_read_string(amount_ptr)
  let new_counter = sdk.kv_increment(b("the_counter"), amount)
  sdk.ret(new_counter)
}
