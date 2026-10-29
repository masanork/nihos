# FatFs source fetch and verified fallback

The normal path downloads the pinned FatFs R0.16 archive and upstream patch 1/patch 2 from [ChaN's distribution](https://elm-chan.org/fsw/ff/), verifies the archive and patch SHA-256 values, applies the patches, and checks the patched `ff.c`. The source and binary redistributions retain the upstream copyright notice and license in the files.

If a transport error prevents the upstream download, the bootstrap can reconstruct the same four output files from commit-pinned mirrors. The patched `ff.c` is fetched from [Zephyr's upstream patch-2 commit](https://github.com/zephyrproject-rtos/fatfs/commit/1df06d036cc57f0abbadfd56b567970d5ccf827c); the remaining three unmodified files come from [a pinned distribution mirror](https://github.com/rondlh/3D-printer-USB-bootloader-for-MAX3421-on-STM32H723/tree/ad13fadc5e0610562364d6d582477e3fa62a7d5c/FATFS). These mirrors are transports, not a new source version. The fallback normalizes their line endings to those produced by the original archive-and-patches path, then verifies the patched `ff.c` and each of the three original extracted file hashes before publishing any of them.

A complete cached source is reused only after all four output hashes match. Any missing or changed file triggers reconstruction.

A checksum mismatch is an integrity failure, not a reason to silently try a different source. The code falls back only on upstream transport failures; every mirror result must match the previously pinned official output byte-for-byte. Tests cover an offline upstream, a corrupted mirror and an official checksum failure. A local run compared the real pinned mirror outputs with all four files reconstructed from the verified upstream archive and patches.
