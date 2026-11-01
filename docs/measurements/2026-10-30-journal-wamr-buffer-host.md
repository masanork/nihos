# Journal admission and WAMR load in one host process

Date: 2026-10-30. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`.

The host runner now builds `nihos-wamr-journal` alongside the original raw-Wasm
fixture. The journal executable accepts only trust/counter/package/root paths.
It reads those files once into private buffers and calls the Zig C ABI
`nih_boot_buffer_admit` before initializing WAMR. The ABI composes the same root
verification, trust decoding, journal integrity and application policy as the
OS boot coordinator. Only successful admission copies the Wasm payload into
the caller's private 4 KiB module buffer. Rejected calls return length zero.
The ABI also accepts the trusted owner's platform service grant and returns
effective services only after successful admission. Rejections clear both
length and effective services. The positive fixture grants graphics and network
at the platform, while the signed package requests graphics alone; the returned
effective mask must be graphics (1), not the wider platform mask (33).

WAMR receives that buffer directly. The owner also keeps a pristine private
copy for repeated load/trap/destroy tests, because WAMR's loader mutates module
names. None of the direct path's initial or repeated loads reads an exported
payload file. The journal input buffers are freed before WAMR initialization;
the admitted copies remain owner-held until all runtime tests finish.

Run the integrated fixture:

```sh
NIHOS_ZIG=/path/to/zig-0.17.0/zig sh probes/wamr-native/run-journal-wamr-host.sh
```

The earlier file-export path remains a separate regression in the same runner.
The direct executable runs the same application assertions: `Ready`/`Pressed`
states, host error and invalid input propagation, nested/wide calls, invalid
guest range trap, text validation, instruction metering, fixed one-page memory,
and 16 trap/destroy cycles returning the runtime pool to its baseline.

Observed direct record:

```text
NIHOS_BOOT_BUFFER status=0 wasm_bytes=1211 services=1
NIHOS_IMPORT_OWNER denied_service=1 inactive=1 mismatched=1 detached=1 calls=0 effective_services=1
WAMR fixed-memory growth rejection: ok
Wasm linear memory range=0..65536 bytes
WAMR pool total=261728 free=239240 highmark=22488 bytes
WAMR 16 trap/destroy cycles returned runtime pool to baseline: ok
WAMR classic interpreter Rust app and bounds: ok
```

The runner also invokes the direct executable with a corrupted package journal,
an incorrect root, a counter behind the trust epoch, and zero platform service
grants for the otherwise unchanged signed graphics application. Each exits with
status 20 and emits only `NIHOS_BOOT_BUFFER status=2 wasm_bytes=0 services=0`. No runtime marker
appears. The C entry point returns before `wasm_runtime_full_init` on admission
failure, so no rejected module reaches the runtime.

The C runtime owner attaches an instance-specific context through WAMR custom
data before calling guest application exports. Both graphics imports require
an attached active context, matching module instance, and the effective graphics
bit. They return the fixture permission error -5 before touching drawing state
or mapping guest text if any check fails. Guest calls in all four denied states
leave accepted host-call count zero. The denied text check additionally uses an
invalid guest offset, confirming permission rejection happens before mapping.
Restoring the owner context then passes the ordinary application assertions.
Every destruction path exercised by the fixture deactivates and detaches its
context before destroying the instance; each repeated load gets its own context.
This is a synchronous single-owner experiment, without concurrent revocation or
cancellation semantics.

The snapshots used by this load adapter are read-only. A lagging counter cannot
be repaired durably here: its advance callback fails, and boot admission stops.
The writable owner must first seal it through the separately tested persistent
file path. This prevents a RAM-only counter update from being presented as a
durable seal.

The 1,211-byte Wasm and 1,419-byte package retain SHA-256 values
`4b226889e627af9ce64ee0b5529d1418cd60afc80944d315ed2b64026dde1710` and
`5958b4dac8881c0ffd7cc3d820072d66afe0b99bb9ed6c535ccb6a1df7be2801`.
Retained [direct runtime log](evidence/2026-10-30-journal-wamr-buffer-host/direct-runtime.log),
[corrupt-package rejection](evidence/2026-10-30-journal-wamr-buffer-host/direct-rejected-corrupt.log),
[wrong-root rejection](evidence/2026-10-30-journal-wamr-buffer-host/direct-rejected-root.log),
[unsealed-counter rejection](evidence/2026-10-30-journal-wamr-buffer-host/direct-rejected-unsealed.log),
[graphics-grant rejection](evidence/2026-10-30-journal-wamr-buffer-host/direct-rejected-denied.log),
[build log](evidence/2026-10-30-journal-wamr-buffer-host/runtime-build.log), and
[artifact hashes](evidence/2026-10-30-journal-wamr-buffer-host/artifacts-sha256.txt)
bind this fixture.

This closes the external payload-file replacement window for this host owner.
The C caller and its native pointers are trusted, snapshots require exclusive
ownership, and the counter is an ordinary file. It does not implement concurrent
trust-update invalidation, a protected counter, native Flash writes, a production
application launcher or physical Tab5 qualification. Existing WAMR sanitizer
and alignment findings retain their prior bounds.
