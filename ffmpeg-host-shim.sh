#!/bin/bash
# Shim to run host's ffmpeg using host's dynamic linker
# This avoids glibc mismatch between container and host
exec /host-libs/lib/ld-linux-x86-64.so.2 \
    --library-path /host-libs/lib:/host-libs/usr-lib:/host-libs/pulseaudio:/host-libs/blas:/host-libs/lapack \
    /host-bin/ffmpeg "$@"
