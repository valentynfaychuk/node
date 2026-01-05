#![no_std]
extern crate alloc;

pub mod context;
pub mod storage;
pub mod encoding;

pub use context::*;
pub use storage::*;
pub use encoding::*;
pub use amadeus_sdk_macros::{contract, Contract};

use core::panic::PanicInfo;

use alloc::{borrow::Cow, vec::Vec, string::String, string::ToString};


#[cfg(not(test))]
#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    loop {}
}

#[global_allocator]
static ALLOC: dlmalloc::GlobalDlmalloc = dlmalloc::GlobalDlmalloc;

#[macro_export]
macro_rules! assert {
    ($cond:expr, $msg:expr) => {
        if !$cond {
            $crate::context::log($msg);

            #[cfg(target_arch = "wasm32")]
            core::arch::wasm32::unreachable();
        }
    };
}

#[macro_export]
macro_rules! abort {
    ($msg:expr) => {
        {
            $crate::context::log($msg);

            #[cfg(target_arch = "wasm32")]
            core::arch::wasm32::unreachable();
        }
    };
}

#[macro_export]
macro_rules! b {
    ( $( $x:expr ),* ) => {
        {
            let mut temp_vec = alloc::vec::Vec::new();
            $(
                temp_vec.extend_from_slice($x.as_ref());
            )*
            temp_vec
        }
    };
}

macro_rules! impl_payload_for_ints {
    ( $($t:ty),* ) => {
        $(
            impl Payload for $t {
                fn to_payload<'a>(&'a self) -> Cow<'a, [u8]> {
                    Cow::Owned(self.to_string().into_bytes())
                }
            }
        )*
    };
}

pub trait Payload {
    fn to_payload<'a>(&'a self) -> Cow<'a, [u8]>;
}

impl Payload for &str {
    fn to_payload<'a>(&'a self) -> Cow<'a, [u8]> { Cow::Borrowed(self.as_bytes()) }
}

impl Payload for String {
    fn to_payload<'a>(&'a self) -> Cow<'a, [u8]> { Cow::Borrowed(self.as_bytes()) }
}

impl Payload for &[u8] {
    fn to_payload<'a>(&'a self) -> Cow<'a, [u8]> { Cow::Borrowed(self) }
}

impl Payload for Vec<u8> {
    fn to_payload<'a>(&'a self) -> Cow<'a, [u8]> { Cow::Borrowed(self.as_slice()) }
}

impl Payload for &alloc::vec::Vec<u8> {
    fn to_payload<'a>(&'a self) -> alloc::borrow::Cow<'a, [u8]> {
        alloc::borrow::Cow::Borrowed(self.as_slice())
    }
}

impl_payload_for_ints!(u8, u16, u32, u64, u128, usize);
impl_payload_for_ints!(i8, i16, i32, i64, i128, isize);

pub struct LazyCell<T> {
    key: Vec<u8>,
    value: core::cell::RefCell<Option<T>>,
    dirty: core::cell::Cell<bool>,
}

impl<T> Default for LazyCell<T> {
    fn default() -> Self {
        Self::new(Vec::new())
    }
}

impl<T> LazyCell<T> {
    pub fn new(key: Vec<u8>) -> Self {
        Self {
            key,
            value: core::cell::RefCell::new(None),
            dirty: core::cell::Cell::new(false),
        }
    }

    pub fn flush(&self) where T: Payload + Clone {
        if self.dirty.get() {
            if let Some(val) = self.value.borrow().as_ref() {
                kv_put(&self.key, val.clone());
            }
        }
    }

    pub fn get(&self) -> T where T: FromKvBytes + Default + Clone {
        if self.value.borrow().is_none() {
            let loaded = kv_get::<T>(&self.key).unwrap_or_default();
            *self.value.borrow_mut() = Some(loaded);
        }
        self.value.borrow().as_ref().unwrap().clone()
    }

    pub fn set(&self, val: T) {
        *self.value.borrow_mut() = Some(val);
        self.dirty.set(true);
    }
}
