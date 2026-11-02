# madowi host loopback baseline

On 2026-11-02, local madowi source commit
`d4d63a4187801b2673fd6391f53140cc86d7cdcc` was tested on the Mac with
`cargo test --offline --locked -p madowi-p2p --lib` and the following filters:

* `two_nodes_sync_hello_roundtrip`: passed (1 test). Two local endpoints
  exchanged `SyncHello` over a bidirectional iroh/QUIC stream using a loopback
  address; this test does not perform the credential authorization exchange.
* `stable_sync_port_is_deterministic_and_in_range`: passed (1 test).
* `new_with_port_binds_requested_port_and_refuses_a_taken_one`: passed (1 test).
* `authz::tests::`: passed (9 tests), including valid, expired, revoked,
  wrong-owner, wrong-session, capability and device-binding cases.

The tests use the locked dependency graph (iroh 1.2.0). The first attempts
in the restricted shell failed with `Operation not permitted` when binding a
socket; rerunning with socket permission passed. Cargo reported an existing
`unused_mut` warning in `mdns.rs`. The target directory was outside the madowi
checkout, and its pre-existing worktree changes were not modified.

This is a host baseline only. It is not evidence of Tab5 packet routing,
P4 UDP sockets, credentialed sync with nihos, LAN discovery, relay operation,
or recovery of the earlier P4 burst failure. No Tab5 was accessed.
