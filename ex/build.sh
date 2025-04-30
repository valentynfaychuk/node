#!/bin/bash

podman run -it --rm -v .:/root/node --entrypoint bash erlang_builder -c "echo 'building amadeus..' \
    && cd /root/node \
    && export MIX_ENV=prod \
    && export RUSTFLAGS='-C target-feature=+avx2,+sse4.2 -C opt-level=3' \
    && mix deps.get \
    && mix release \
    && cp _build/prod/rel/bakeware/ama amadeusd"
b3sum amadeusd
