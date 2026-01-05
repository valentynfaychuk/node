#![no_std]
#![no_main]

extern crate alloc;
use alloc::vec::Vec;
use alloc::string::ToString;
use amadeus_sdk::*;

#[derive(Contract, Default)]
struct SimpleCounter {
    count: LazyCell<i128>,
    owner: LazyCell<Vec<u8>>,
}

#[contract]
impl SimpleCounter {
    pub fn init(&mut self) {
        self.owner.set(account_current());
        self.count.set(0);
        log("Counter initialized");
    }

    pub fn increment(&mut self, amount: Vec<u8>) {
        let amount_val = i128::from_bytes(amount);
        let current = self.count.get();
        self.count.set(current + amount_val);
    }

    pub fn get(&self) -> Vec<u8> {
        self.count.get().to_string().into_bytes()
    }

    pub fn reset(&mut self) {
        let caller = account_caller();
        let owner = self.owner.get();
        amadeus_sdk::assert!(caller == owner, "unauthorized");
        self.count.set(0);
    }
}
