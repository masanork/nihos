# P4 RNG gate emulator fixture

Run `NIHOS_EMU=/path/to/esp-emu-0.50.0/esp-emu sh probes/p4-rng-gate/run-emulator.sh` with Zig 0.17.0 in `.tools`, or set `ZIG` and `NIHOS_TOOLS_ROOT`. The script applies the test-only patch in a temporary detached worktree and preserves the audited image, ELF, hashes and log under `build/`. Never flash the generated image.

The normal headless emulator boot runs the actual `p4_rng_gate.Gate` implementation on CPU0. It checks exclusion of SQLite and entropy tokens, stale token rejection and reacquisition. It does not run SQLite or the entropy backend, simulate concurrent contenders, or access the RNG register. Host tests cover the backend and gate with simulated ADC cleanup. Neither establishes native ADC/analog/clock ownership, hardware entropy quality or Tab5 behavior.
