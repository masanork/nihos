//! Experimental host-testable log-store engine. No native mount or driver is
//! registered by importing this module; persistent hardware qualification and
//! a stable public storage ABI remain separate work.
pub const publication_model = @import("cow_model.zig");
pub const sector_media = @import("sector_media.zig");
pub const file_media = @import("file_media.zig");
pub const checkpoint = @import("checkpoint_model.zig");
pub const service = @import("checkpoint_service.zig");

test {
    _ = publication_model;
    _ = file_media;
    _ = sector_media;
    _ = @import("sector_media_test.zig");
    _ = checkpoint;
    _ = service;
    _ = service.reader_drain;
    _ = service.deadline;
    _ = service.recovery_budget;
    _ = @import("cow_model_test.zig");
    _ = @import("model_media.zig");
    _ = @import("file_media_test.zig");
    _ = @import("editor_document_test.zig");
    _ = @import("editor_sd_path_test.zig");
    _ = @import("checkpoint_model_test.zig");
    _ = @import("range_checksum_test.zig");
    _ = @import("index_gc_test.zig");
    _ = @import("payload_gc_test.zig");
    _ = @import("search_cache_test.zig");
    _ = @import("stream_test.zig");
    _ = @import("extent_map_test.zig");
    _ = @import("resize_test.zig");
    _ = @import("batch_test.zig");
    _ = @import("scatter_test.zig");
    _ = @import("reservation_test.zig");
    _ = @import("dispatch_gate_test.zig");
    _ = @import("lifetime_budget_test.zig");
    _ = @import("lifetime_usage_test.zig");
    _ = @import("object_pin_test.zig");
    _ = @import("checkpoint_service_test.zig");
}
