# SSH authentication on the PSRAM stack: emulator fixture

Run `NIHOS_EMU=/path/to/esp-emu-0.50.0/esp-emu sh probes/ssh-stack/run-auth-emulator.sh` with Zig 0.17.0 available in `.tools`, or set `ZIG` and `NIHOS_TOOLS_ROOT`. The script applies its test-only patch in a detached temporary worktree and retains the audited images, hashes and log under `build/`. Never flash those images.

Run `python3 probes/ssh-stack/auth-reference.py` with the Python `cryptography` package to independently regenerate the expected packet and verify that changing the session identifier or signed payload rejects the signature.

The callback invokes the real SSH public-key authentication packet builder using the fixed, non-secret Ed25519 seed `42` repeated 32 times and session identifier `24` repeated 32 times. It checks the packet SHA-256 against `04b2fbeac6ba3b1081d5b910f1bceb269e4514a07c37689d80ce4f60c6edae0d`, independently computed with Python cryptography's Ed25519 implementation and SSH wire encoding. The fixture also checks stack switching, timer progress, nested admission rejection, ownership release and stack clearing. Stack usage is a paint watermark for this single input, not a worst-case bound.

The fixture-only link moves `crypto.25519.scalar.Scalar.fromBytes` into boot Flash and adds that exact symbol to a fixture-only audit, including a check for an SRAM copy. It retains the normal 49,152-byte heap minimum; the recorded image has 49,408 bytes. This narrow emulator result does not establish cache-off or interrupt safety of Flash execution. It uses no production entropy or network, and does not enable native SSH. Real entropy, transport integration, memory headroom, full execution-path safety and physical device validation remain open.
