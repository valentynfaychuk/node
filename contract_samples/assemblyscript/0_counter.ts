import * as sdk from "./sdk";
import { b, b58 } from "./sdk";

export function get(): void {
  sdk.log(`get called`)
  let cur_counter = sdk.kv_get_or<i64>(b("the_counter"), 0)
  assert(cur_counter > 10, "counter is over 10")
  sdk.ret(cur_counter)
}

function loop(num: i32): void {
  while(1) {
    num = num + 1;
  }
}

export function increment(amount_ptr: i32): void {
//  let amount = sdk.memory_read_string(amount_ptr);
//  let new_counter = sdk.kv_increment("the_counter", amount);
//  sdk.return_value(new_counter);
}
