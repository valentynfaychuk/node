#![no_std]
#![no_main]

extern crate alloc;
use alloc::vec::Vec;
use alloc::string::ToString;
use amadeus_sdk::*;

#[contract_state]
struct SimpleCounter {
    count: i128,
    owner: Vec<u8>,
}

#[contract]
impl SimpleCounter {
    pub fn init(&mut self) {
        *self.owner = account_current();
        *self.count = 0;
        log("Counter initialized");
    }

    pub fn increment(&mut self, amount: Vec<u8>) {
        *self.count += i128::from_bytes(amount);
    }

    pub fn get(&self) -> Vec<u8> {
        (*self.count).to_string().into_bytes()
    }

    pub fn reset(&mut self) {
        let caller = account_caller();
        amadeus_sdk::assert!(*self.owner == caller, "unauthorized");
        *self.count = 0;
    }
}
