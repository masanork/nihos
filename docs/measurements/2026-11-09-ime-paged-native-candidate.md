# Experimental native paged IME candidate

`NIHOS_NATIVE_IME_PAGED=1 sh tools/build-native.sh device` enables an
experimental foreground bridge to the permanent sqld owner's dictionary
mailbox. The ordinary build leaves this feature disabled. The bridge keeps
its workspace allocation until pending requests are drained, the IME is
detached and the owner acknowledges release; a mismatched completion keeps
the workspace fenced. A missing dictionary leaves the builtin IME in place.
Workspace reset is deferred while the bridge still owns the workspace.

The initial integration exceeded the 49,152-byte SRAM heap floor. It also
generated a large foreground stack temporary and two multi-kilobyte default
initializers in SRAM. The bridge/runtime and sliced conversion now initialize
in place, and the foreground-only conversion functions are explicitly placed
in audited mapped Flash. The candidate linked with heap boundaries
`0x4ff1b040..0x4ff28000` (53,184 bytes), retaining 4,032 bytes above the floor.
The floor itself is unchanged. This is link-time placement evidence, not a
whole-call-stack or cache-off proof.
The structural inventory rooted at `Runtime.pollPort` reported a 2,272-byte
known partial chain, one missing frame and two unresolved jump tables. It is
not a peak bound and does not cover the complete foreground entry chain.

The current native store has only 4 MiB and a 1 MiB object limit, so the
large dictionary cannot yet be installed. This build has not been flashed or
run on Tab5. SD removal, physical power loss, memory/cache coherency and peak
stack while converting remain unqualified; do not promote the flag to the
ordinary image on the strength of this build alone.
