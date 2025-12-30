#![no_std]
#![no_main]
extern crate alloc;
use amadeus_sdk::*;
use alloc::string::String;
use alloc::vec::Vec;

#[no_mangle]
pub extern "C" fn init() {
    log("Init called during deployment of contract");
    kv_put("inited", "true");
}

#[contract]
fn get() -> i128 {
    kv_get("the_counter").unwrap_or(0)
}

#[contract]
fn increment(amount: Vec<u8>) -> String {
    kv_increment("the_counter", amount)
}

#[contract]
fn increment_another_counter(contract: Vec<u8>) -> Vec<u8> {
    let incr_by = 3i64;
    log("increment_another_counter");
    call!(contract.as_slice(), "increment", [incr_by])
}

#[contract]
fn set_message(msg: String) {
    kv_put("message", msg);
}

#[contract]
fn add_value(key: Vec<u8>, value: Vec<u8>) {
    kv_put(key, value);
}
