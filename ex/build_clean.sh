#!/bin/bash

#&& export ERL_COMPILER_OPTIONS=bin_opt_info \

podman run -it --rm -v ../.:/root/node --entrypoint bash erlang_builder -c "echo 'building amadeus..' \
    && cd /tmp \
    && git clone https://github.com/amadeusprotocol/node \
    && cd /tmp/node/ex \
    && export MIX_ENV=prod \
    && export CC='clang-19' CXX='clang++-19' CFLAGS='-march=haswell' CXXFLAGS='-march=haswell' \
    && export RUSTFLAGS='-C target-cpu=haswell -C opt-level=3' \
    && export LLVM_CONFIG_PATH=/usr/bin/llvm-config-19 LIBCLANG_PATH=/usr/lib/llvm-19/lib \
    && mix deps.get \
    && mix release \
    && cp _build/prod/rel/bakeware/ama /root/node/ex/amadeusd"
sha256sum amadeusd
