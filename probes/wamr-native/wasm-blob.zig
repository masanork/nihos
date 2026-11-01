// Copy this module beside the exact built app.wasm before compiling its caller.
pub const bytes = @embedFile("app.wasm");
