# Native source inventories

The native CI workflow generates CycloneDX 1.6 inventories
for the normal Tab5 device build, retaining them with the image evidence:

* `audited-inputs.cdx.json` records the SHA-256 of the bootloader, partition
  table and application binaries after matching their flash-image slices. It
  also identifies FatFs and SQLite when the image audit
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
checks the audit hashes of the application ELF, application binary, loader ELF
and loader configuration. It checks the bootloader at `0x2000`, partition table
at `0x8000` and application at `0x10000` against their binary files, requires
non-overlapping nonempty regions and erased (`0xff`) padding, and rejects
trailing data. These checks establish byte consistency, not that the current
source produced the image or that the loader ELF produced the bootloader
binary. The source inventory and image must come from the same clean build for
the results to be meaningful. No secret values are collected.

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

## Experimental signed build provenance

The manually dispatched `Native boot` workflow has an opt-in `attest` input.
It invokes `native-provenance.yml` as a reusable workflow on a GitHub-hosted
runner. That workflow builds the normal device image without Wi-Fi credentials,
generates the three partial inventories, and signs build provenance for the
flash image and each inventory file. It verifies all subjects against the
repository, reusable signer workflow, signer revision and source commit. It
checks that a modified image and an incorrect signer workflow fail verification.
It retains the image, ELF, audit, inventories and signed bundle as an artifact.

To verify a downloaded image online, substitute the trusted source and workflow
commit SHAs:

```sh
gh attestation verify nihos-native-flash.bin --repo masanork/nihos \
  --signer-workflow masanork/nihos/.github/workflows/native-provenance.yml \
  --source-digest TRUSTED_COMMIT_SHA --signer-digest TRUSTED_WORKFLOW_SHA \
  --deny-self-hosted-runners
```

Use the same command with each inventory filename to verify that file. Signing
these candidate files does not make them complete SBOMs or assert that every
listed crypto asset is in the image. The ordinary native qualification job is
separate and can fail independently; neither signed provenance nor a successful
build is a device test or release approval. This experimental workflow is not an
assessment or claim of SLSA Build Level 3: the reusable workflow is taken from
the same source revision as the caller, so consumers must trust and verify both
revisions. It still requires an independent assessment of builder isolation and
provenance integrity, dependency controls and a verified release process.

## Experimental consumer policy

After obtaining the expected commit SHA independently, verify the downloaded
image and all three inventory files as one artifact set:

```sh
python3 tools/verify_native_provenance.py PATH/TO/IMAGE-DIRECTORY \
  --source-sha TRUSTED_COMMIT_SHA
```

The directory must contain `nihos-native-flash.bin` and the three `.cdx.json`
files under `bom/`. The optional `--bundle PATH` uses a downloaded Sigstore
bundle; this does not by itself provide all requirements for offline trust-root
verification. `gh` must be installed and able to verify the attestation. The
policy defaults to `refs/heads/main`; a different `--source-ref` is intended
for explicit test builds and must itself be trusted independently.

The tool first invokes `gh attestation verify`, requiring the expected repository,
source ref and commit, reusable signer path and commit, and a GitHub-hosted
runner. It then checks the verified statement's exact four subject names and
local SHA-256 digests, the inventory image hashes, build type, caller workflow,
branch, builder identity, source dependency, and workflow-dispatch event. It
rejects unexpected external parameters. It does not infer the trusted commit
from the artifact or attestations. The current GitHub statement does not expose
all build inputs or prove inventory completeness, dependency integrity, actual
device behavior, a release decision, or SLSA Build Level 3.
