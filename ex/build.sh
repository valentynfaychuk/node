#!/bin/bash

#podman build --tag farm_builder ../docker/compile/
podman run -it --rm -v .:/root/node --entrypoint bash erlang_builder -c "echo 'building amadeus..' \
    && cd /root/node \
    && export MIX_ENV=prod \
    && rm -rf _build \
    && mix deps.get \
    && mix release \
    && cp _build/prod/rel/bakeware/ama amadeusd"
b3sum amadeusd
