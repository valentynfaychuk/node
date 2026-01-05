#![no_std]
#![no_main]

extern crate alloc;
use alloc::vec::Vec;
use alloc::string::ToString;
use amadeus_sdk::*;

#[contract_state]
struct Metadata {
    owner: Vec<u8>,
    created_at: i128,
}

#[contract_state]
struct Counter {
    count: i128,
    #[nested]
    metadata: Metadata,
}

#[contract]
impl Counter {
    pub fn init(&mut self) {
        *self.metadata.owner = account_current();
        *self.metadata.created_at = entry_slot() as i128;
        *self.count = 0;
    }

    pub fn increment(&mut self, amount: Vec<u8>) {
        *self.count += i128::from_bytes(amount);
    }

    pub fn get(&self) -> Vec<u8> {
        (*self.count).to_string().into_bytes()
    }

    pub fn reset(&mut self) {
        let caller = account_caller();
        amadeus_sdk::assert!(*self.metadata.owner == caller, "unauthorized");
        *self.count = 0;
    }
}
