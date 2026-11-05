# Native source inventories

The native CI workflow generates CycloneDX 1.6 inventories
for the normal Tab5 device build, retaining them with the image evidence:

* `audited-inputs.cdx.json` identifies FatFs and SQLite when the image audit
  contains the corresponding normal FS and sqld identities. The generator checks
  those identity digests, the FatFs source pin and the current SQLite source
  hash. It is a partial inventory, not a complete firmware SBOM.
* `source-sbom.cdx.json` copies the source catalogue in `provenance.toml`.
  It includes reference-only, test and optional entries; it is not a list of
  components in the firmware. Licenses are recorded as the original descriptive
  text, not as validated SPDX expressions.
* `source-cbom.cdx.json` scans Zig source under `src/` for a small, explicit
  set of cryptographic identifiers. Matches include comments and tests. It is
  not a complete crypto inventory and does not establish that a match is linked,
  enabled, or used. C sources, generated code, Zig standard library internals,
  external components, bootloader and C6 firmware are not covered. RSA-2048
  candidates include generic 2048-bit finite-field declarations because the
  NPA card verifier uses that API; such a match alone does not establish RSA
  use. The verifier is built only in selected card profiles.

The image audit and manifests are local unsigned evidence: the generator checks
consistency with them, not their authenticity. It does not rerun the native
image auditor.

Each document identifies the supplied flash image by SHA-256. The generator
checks that the image audit matches the ELF and application image and that the
flash image contains the audited application at offset `0x10000`. This is an
integrity check, not proof that the current source produced the image. The
source inventory and image must come from the same clean build for the results
to be meaningful. The bootloader and partition table are not independently
verified by this check. No secret values are collected.

For a fresh ordinary build (Python 3.11+):

```sh
sh tools/build-native.sh device
python3 tools/supply_chain_bom.py build/native-device-network-devices-camera-sqld build/native-device-network-devices-camera-sqld/bom
```

Do not use these candidate reports as a complete product SBOM/CBOM or as a
license, vulnerability, cryptographic compliance or SLSA attestation. Future
work must resolve actual build inputs and configuration per artifact, review
crypto usage and coverage, verify generated documents against the CycloneDX
schema, and bind release artifacts to signed provenance. SLSA Build Level 3
requires a separately evaluated isolated build and trusted provenance process;
this workflow does not claim it.
