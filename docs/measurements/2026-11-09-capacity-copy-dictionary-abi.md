# Host capacity copy with dictionary ABI

This integration combines the independent capacity-copy prototype and the
separately compiled host-only 32 MiB store ABI. A disposable 4 MiB image is
created with the real SQLite service and a Japanese row. The source image is
copied into a distinct 32 MiB checkpoint image; the dictionary is imported as
key 64 through the owner ABI in 4 KiB copies, then the destination is reopened.
The test checks every legacy object, every imported dictionary byte, the
source SHA-256, SQLite integrity and the row, and dictionary lookup `かんじ`
to `漢字`.

The CI fixture expands the bundled small NFST with unreferenced arena bytes to
exercise a 5,129,285-byte object. It does not test large-dictionary quality.
An optional run with `NIHOS_NFST_PATH` uses an externally supplied real large
NFST. The 32 MiB ABI is a separate host object, because Zig's test runner root
does not itself carry the ABI's compile-time geometry declaration.

Both images are disposable regular files. File barriers and the host model do
not establish physical SD durability, disjoint card regions, native task
scheduling, cutover authority, Tab5 behavior or real power-loss recovery.
No native migration or dictionary provisioner is enabled by this test.
