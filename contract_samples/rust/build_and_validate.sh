#!/bin/bash
set -e

cargo build -p amadeus-sdk --example counter --target wasm32-unknown-unknown --release
cargo build -p amadeus-sdk --example deposit --target wasm32-unknown-unknown --release
cargo build -p amadeus-sdk --example coin --target wasm32-unknown-unknown --release
cargo build -p amadeus-sdk --example nft --target wasm32-unknown-unknown --release

wasm-opt -Oz --enable-bulk-memory target/wasm32-unknown-unknown/release/examples/counter.wasm -o target/wasm32-unknown-unknown/release/examples/counter_opt.wasm
wasm-opt -Oz --enable-bulk-memory target/wasm32-unknown-unknown/release/examples/deposit.wasm -o target/wasm32-unknown-unknown/release/examples/deposit_opt.wasm
wasm-opt -Oz --enable-bulk-memory target/wasm32-unknown-unknown/release/examples/coin.wasm -o target/wasm32-unknown-unknown/release/examples/coin_opt.wasm
wasm-opt -Oz --enable-bulk-memory target/wasm32-unknown-unknown/release/examples/nft.wasm -o target/wasm32-unknown-unknown/release/examples/nft_opt.wasm

curl -X POST -H "Content-Type: application/octet-stream" --data-binary @target/wasm32-unknown-unknown/release/examples/counter_opt.wasm https://mainnet-rpc.ama.one/api/contract/validate
curl -X POST -H "Content-Type: application/octet-stream" --data-binary @target/wasm32-unknown-unknown/release/examples/deposit_opt.wasm https://mainnet-rpc.ama.one/api/contract/validate
curl -X POST -H "Content-Type: application/octet-stream" --data-binary @target/wasm32-unknown-unknown/release/examples/coin_opt.wasm https://mainnet-rpc.ama.one/api/contract/validate
curl -X POST -H "Content-Type: application/octet-stream" --data-binary @target/wasm32-unknown-unknown/release/examples/nft_opt.wasm https://mainnet-rpc.ama.one/api/contract/validate
