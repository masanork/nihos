# Hosted 3 updater pre-token preflight on Tab5

On 2026-11-02 JST, the actual-update P4 fixture built from clean commit
`e53c75a571625ef969f6247a828bf7a64cb530fc` was run only up to its one-shot
start gate. Its P4 app SHA-256 was
`8c0ea479992260650377fac6eaecda31b3b0ad63dd94fad4265cf9c0083280b1`.
It computed the mapped C6 3.0.10 candidate's 1,397,104-byte SHA-256
`04bd14faf943453ccf39075bc61456463b3f362643a3a63dab0f82a53f4dc8fe`,
observed C6 chip 13 / Hosted version 2.13.1 and emitted the start-ready line.
The physical runner did not send the token; the captured console contains no
OTA-progress, transfer-result or post-update event. No independent packet
capture was made, and neither the C6 flash nor its partition table was read.

The P4 write lock and kernel-enforced serial lease were held throughout.
The then-current 16 MiB P4 flash was backed up and verified before installing
the fixture, and the full flash was restored and verified afterward against
backup SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
The restored P4 app was reset but its boot was not captured. Capture SHA-256:
`284c91db8bb5ece781008c1d4c3dffe526104d3f5dc7af0617a6695920034a09`.
The raw capture, P4 artifacts and private backup are under
`/private/tmp/nihos-hosted3-update-preflight-20261102/`.

The [redacted checker result](evidence/2026-11-02-hosted3-updater-preflight.json)
validates event order, exact candidate digest and origin, and rejects
simulation, update and failure events. Its unit tests exercise invalid
captures. The checker does not establish P4 byte identity, device ownership,
whether a token was sent, or C6 flash state; those are external runner facts.
This result is a pre-token gate, not a completed OTA or evidence that 3.0.10
boots or can be independently recovered. The application-description check
was a separate earlier physical run, not part of this fixture or lease.
