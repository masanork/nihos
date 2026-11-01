# Hosted 3 candidate: P4 OTA simulation on Tab5

On 2026-11-01, Tab5 ran the P4-only OTA simulation built from clean commit
`a3dce80c54204eb11b3d8ed31ca51aab28e8e013`. Its P4 app SHA-256 was
`bc6988a2bc0795c99a8ea91036f94953756fe7be542db129af99499b935607a6`.
The mapped C6 3.0.10 candidate was 1,397,104 bytes, SHA-256
`04bd14faf943453ccf39075bc61456463b3f362643a3a63dab0f82a53f4dc8fe`.
The P4 computed that exact size and digest from the mapped bytes at runtime.

The physical Hosted handshake reported C6 chip 13 and version 2.13.1. After
the explicit simulation marker and reviewed-candidate token, the P4 in-memory
responder acknowledged all 1,397,104 candidate bytes, including the explicit
activation phase used by the 2.13.1 sender. The P4 then performed another
physical handshake and again reported 2.13.1. The physical stream was wrapped
to reject OTA Begin, Write, End and Activate, including the post-simulation
handshake. This is a source and host-test property; no packet capture was
made. The C6 application was not updated by this simulation. The earlier
physical-update evidence checker explicitly rejected this capture because
it contains the simulation marker.

Before installation the test held the device write lock and kernel-enforced
serial lease, identified the P4, backed up its then-current 16 MiB flash and
verified the backup against the device. It restored the P4 and verified the
entire flash against backup SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
The restored application was reset, but its boot was not captured. The serial
capture SHA-256 was
`c10dedd12ac7f4e9f4105f05b8beadd53c470c6d8e15052d5ddb981550d7255a`.
The redacted result, private raw capture and backup are in
`/private/tmp/nihos-hosted3-simulation-physical-20261101-final/`.

An independent host test hashed the same candidate and completed the same
in-memory transfer with explicit activation. Neither host nor device
simulation establishes C6 flash contents, 3.0.10 boot, C6 OTA completion,
rollback, or an independent recovery route. Those remain separate gates.
