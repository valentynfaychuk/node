import * as sdk from "./sdk";

export function get(): void {
  let cur_counter = sdk.kv_get<i64>("the_counter");
  sdk.return_value(cur_counter);
}

export function increment(amount_ptr: i32): void {
  let amount = sdk.memory_read_string(amount_ptr);
  let new_counter = sdk.kv_increment("the_counter", amount);
  sdk.return_value(new_counter);
}
