//! Boot-time composition of the persistent trust and package journals.
//!
//! This is the only path that turns persisted bytes into a package that may be
//! handed to an application runtime. It owns neither the storage media nor the
//! protected monotonic counter. The returned package slice borrows the caller's
//! package workspace and remains valid only until that workspace is reused.
const std = @import("std");
const install = @import("app_install");
const policy = @import("app_policy");
const package_ed25519 = @import("package_ed25519");
const snapshot_ed25519 = @import("trust_snapshot_ed25519");
const snapshot_store = @import("trust_snapshot_store");

pub const Inputs = struct {
    trust_storage: snapshot_store.Storage,
    monotonic: snapshot_store.Monotonic,
    trust_layout: snapshot_store.Layout,
    roots: *snapshot_ed25519.RootStore,
    package_storage: install.Storage,
    package_layout: install.Layout,
    max_signature_bytes: u16,
    limits: policy.Limits,
};

pub const Workspace = struct {
    snapshot_bytes: []u8,
    package_bytes: []u8,
    package_keys: []package_ed25519.KeyRecord,
    rollback: []package_ed25519.RollbackRecord,
};

pub const Ready = struct {
    trust_epoch: u64,
    installed: install.Installed,
    package_bytes: []const u8,
};

pub const InstalledReady = struct {
    ready: Ready,
    disposition: install.Disposition,
};

/// A recovery-authority snapshot is valid persistent state, but it is not an
/// application-launch authority. The OS must remain in maintenance until a
/// new normal-authority snapshot is installed.
pub const Result = union(enum) {
    unprovisioned,
    no_package: u64,
    recovery_maintenance: u64,
    ready: Ready,
};

pub const Error = error{
    Busy,
    InvalidTrustSnapshot,
    TrustEpochMismatch,
    TrustNotProvisioned,
    RecoveryAuthorityActive,
} || snapshot_ed25519.RootStore.Error || snapshot_store.Error ||
    snapshot_ed25519.DecodeError || package_ed25519.Store.SnapshotError || install.Error;

pub const Coordinator = struct {
    active: std.atomic.Value(bool) = .init(false),

    /// Recovers and seals trust before examining the package journal. The
    /// atomic gate rejects re-entry and cross-hart overlap; callers must still
    /// ensure the supplied adapters are exclusively owned for the full call.
    pub fn recover(
        self: *Coordinator,
        inputs: Inputs,
        workspace: Workspace,
    ) Error!Result {
        if (self.active.swap(true, .acq_rel)) return error.Busy;
        defer self.active.store(false, .release);

        const authenticator = try inputs.roots.authenticator();
        const trust_state = (try snapshot_store.recoverAndSeal(
            inputs.trust_storage,
            inputs.monotonic,
            authenticator,
            inputs.trust_layout,
            workspace.snapshot_bytes,
        )) orelse return .unprovisioned;
        const snapshot_bytes = try snapshot_store.readSnapshot(
            inputs.trust_storage,
            inputs.trust_layout,
            trust_state,
            workspace.snapshot_bytes,
        );
        const parsed = inputs.roots.verify(snapshot_bytes) orelse
            return error.InvalidTrustSnapshot;
        if (parsed.epoch != trust_state.epoch) return error.TrustEpochMismatch;
        if (parsed.authority == .recovery)
            return .{ .recovery_maintenance = parsed.epoch };

        var package_trust = try snapshot_ed25519.decodePackageStore(
            parsed,
            workspace.package_keys,
            workspace.rollback,
        );
        const provider = try package_trust.trustProvider();
        const verification = install.Verification{
            .trust_epoch = parsed.epoch,
            .max_signature_bytes = inputs.max_signature_bytes,
            .trust = provider,
            .limits = inputs.limits,
        };
        const installed = (try install.recover(
            inputs.package_storage,
            inputs.package_layout,
            verification,
            workspace.package_bytes,
        )) orelse return .{ .no_package = parsed.epoch };
        const package_bytes = try install.readInstalled(
            inputs.package_storage,
            inputs.package_layout,
            installed,
            workspace.package_bytes,
        );
        return .{ .ready = .{
            .trust_epoch = parsed.epoch,
            .installed = installed,
            .package_bytes = package_bytes,
        } };
    }

    /// Installs a signed candidate under the currently sealed normal trust
    /// snapshot, then reads back the committed bytes. Recovery-authority state
    /// can repair trust but cannot install or launch applications.
    pub fn installPackage(
        self: *Coordinator,
        inputs: Inputs,
        workspace: Workspace,
        candidate: []const u8,
    ) Error!InstalledReady {
        if (self.active.swap(true, .acq_rel)) return error.Busy;
        defer self.active.store(false, .release);

        const authenticator = try inputs.roots.authenticator();
        const trust_state = (try snapshot_store.recoverAndSeal(
            inputs.trust_storage,
            inputs.monotonic,
            authenticator,
            inputs.trust_layout,
            workspace.snapshot_bytes,
        )) orelse return error.TrustNotProvisioned;
        const snapshot_bytes = try snapshot_store.readSnapshot(
            inputs.trust_storage,
            inputs.trust_layout,
            trust_state,
            workspace.snapshot_bytes,
        );
        const parsed = inputs.roots.verify(snapshot_bytes) orelse
            return error.InvalidTrustSnapshot;
        if (parsed.epoch != trust_state.epoch) return error.TrustEpochMismatch;
        if (parsed.authority == .recovery) return error.RecoveryAuthorityActive;

        var package_trust = try snapshot_ed25519.decodePackageStore(
            parsed,
            workspace.package_keys,
            workspace.rollback,
        );
        const provider = try package_trust.trustProvider();
        const verification = install.Verification{
            .trust_epoch = parsed.epoch,
            .max_signature_bytes = inputs.max_signature_bytes,
            .trust = provider,
            .limits = inputs.limits,
        };
        const outcome = try install.install(
            inputs.package_storage,
            inputs.package_layout,
            candidate,
            verification,
            workspace.package_bytes,
        );
        const package_bytes = try install.readInstalled(
            inputs.package_storage,
            inputs.package_layout,
            outcome.state,
            workspace.package_bytes,
        );
        return .{
            .ready = .{
                .trust_epoch = parsed.epoch,
                .installed = outcome.state,
                .package_bytes = package_bytes,
            },
            .disposition = outcome.disposition,
        };
    }
};
