# xy landing checks and macOS rendering regression

The landing branch rebases the native scratch/system-buffer/Scheme work onto
main and explicitly documents the actual frontend connections. Both ordinary
frontends share `document.zig`; the native scratch still uses the fixed raster
and new bounded Scheme runtime, while the Cocoa C ABI uses the OpenType/layout
frontend and previous fixed-form evaluator. Sharing those remaining connections
is a follow-up, not a completed part of this landing.

Running the committed macOS snapshot frontend with all six local Bunsen font
layers exposed a pre-existing rasterizer overflow: scaling a 1000-em square at
36 px overflowed an i32 numerator during 16.16 X-coordinate conversion before
division. A synthetic-font coverage regression fails on that expression without
any workspace/Document dependency. The conversion now widens the numerator to
i64 and narrows after division. The focused test passes with exactly 36×36 fully
covered pixels. Real horizontal Mincho, vertical Mincho and vertical Gothic
snapshots all complete in ReleaseSafe; the vertical size change retains the
outline cache and reads zero extra font bytes. These are host rendering checks,
not physical panel or input qualification.

The shipped keypad/card font binary hashes were verified unchanged before
refreshing only the source-identity entries for native main and linker changes.
The JSON files are asset/audit manifests. User-editable xy configuration is to
use S-expressions, as specified in the extension-language plan.

[macOS snapshots and regression evidence](evidence/2026-10-31-xy-main-landing/mac-snapshot-evidence.json)


The driver/storage-disabled connected profile also keeps the ordinary xy font.
Without the filesystem Flash span its font masks previously overflowed the
boot-record page. This profile now places the same masks in xy's read-only
Flash region; filesystem-enabled profiles retain their existing font placement.
The exact CI configuration (`NIHOS_NATIVE_DEVICES=0 NIHOS_NATIVE_NORMAL_STORAGE=0`)
builds and passes the image audit locally, without changing the font bytes or
relaxing the existing region/SRAM limits. Its build log and audit are retained
beside the macOS evidence.
