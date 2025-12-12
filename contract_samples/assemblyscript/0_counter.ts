import * as sdk from "./sdk";
import { b, b58 } from "./sdk";

export function get(): void {
  sdk.log(b(`get called`))
  if (sdk.kv_exists(b("the_counter"))) {
    sdk.log("exists")
  }
  let cur_counter = sdk.bToI64(sdk.kv_get("the_counter"))
  sdk.kv_put("the_counter", "1")
  sdk.kv_put(b("the_counter1"), b("1"))
  sdk.kv_put(b("the_counter2"), b("1"))
  sdk.kv_put(b("the_counter3"), b("1"))

  let last_key = b("the_counter4")
  while(1) {
    let kv = sdk.kv_get_prev(b(""), last_key);
    sdk.log(kv.key);
    sdk.log(kv.value);
    if (kv.key == null) break;
    last_key = kv.key!;
  }
  //sdk.kv_delete(b("the_counter"))
  //let new_counter = sdk.kv_increment(b("the_counter"), "1")
  //assert(cur_counter < 10, "counter is over 10")
  sdk.ret(cur_counter)
}

export function increment(amount_ptr: i32): void {
  let amount = sdk.memory_read_string(amount_ptr)
  let new_counter = sdk.kv_increment(b("the_counter"), amount)
  sdk.ret(new_counter)
}

export function roll_dice(): void {
  const val = Math.random(); // Returns 0.0 to 1.0
  let roll = floor(val * 6) as i32 + 1;
  sdk.ret(roll)
}
