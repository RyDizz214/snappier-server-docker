#!/bin/bash
# Shim to run host's ffprobe using host's dynamic linker
exec /host-libs/lib/ld-linux-x86-64.so.2 \
    --library-path /host-libs/lib:/host-libs/usr-lib:/host-libs/pulseaudio:/host-libs/blas:/host-libs/lapack \
    /host-bin/ffprobe "$@"
