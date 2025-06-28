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

export function burn(amount_ptr: i32): void {
  let amount = sdk.memory_read_string(amount_ptr);

  let result = sdk.call(sdk.bin("Coin"), "transfer", [(new Uint8Array(48)).buffer, sdk.bin(amount), sdk.bin("AMA")])
  assert(1>2, "1 not more than 2")
  //let new_counter = sdk.call(
  //  sdk.base58_decode("7d7f7PRHW9UseRNC9GR4n7ubcc2aWpgezuz6GM58MazdFvWMh862dSUF2i3fuTmzay").buffer,
  //  "increment",
  //  [sdk.bin("10")])
  sdk.log(result)
  sdk.return_value(result);
}
