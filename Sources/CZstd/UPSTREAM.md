# Zstandard decoder

Source: https://github.com/facebook/zstd/releases/tag/v1.5.7

Pinned release: 1.5.7. Tarball SHA-256: `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`.

`zstddeclib.c` is generated without modifications using upstream `build/single_file_libs/create_single_file_decoder.sh`. `include/zstd.h`, `include/zstd_errors.h` and `LICENSE` are copied from the same release. The app statically links only the decoder; no Homebrew dependency or shell decompression at runtime. Distributed under the included BSD license.
