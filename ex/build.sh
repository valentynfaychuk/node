#!/bin/bash

podman run -it --rm -v ../.:/root/node --entrypoint bash erlang_builder -c "echo 'building amadeus..' \
    && cd /root/node/ex \
    && export MIX_ENV=prod \
    && export CC='clang-19' CXX='clang++-19' CFLAGS='-march=haswell' CXXFLAGS='-march=haswell' \
    && export RUSTFLAGS='-C target-cpu=haswell -C opt-level=3' \
    && export LLVM_CONFIG_PATH=/usr/bin/llvm-config-19 LIBCLANG_PATH=/usr/lib/llvm-19/lib \
    && mix deps.get \
    && mix release \
    && cp _build/prod/rel/bakeware/ama amadeusd"
sha256sum amadeusd
