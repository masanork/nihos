use std::{env, path::PathBuf, process::Command};

fn main() {
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let output = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    println!("cargo:rerun-if-changed={}", root.join("src").display());
    println!(
        "cargo:rerun-if-changed={}",
        root.join("tools/bootstrap-zig.sh").display()
    );
    println!("cargo:rerun-if-env-changed=ZIG");
    let zig = env::var("ZIG").unwrap_or_else(|_| {
        let result = Command::new("sh")
            .arg(root.join("tools/bootstrap-zig.sh"))
            .current_dir(&root)
            .output()
            .expect("bootstrap pinned Zig");
        assert!(
            result.status.success(),
            "Zig bootstrap failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );
        String::from_utf8(result.stdout).unwrap().trim().to_owned()
    });
    let status = Command::new(zig)
        .current_dir(&root)
        .args([
            "build-lib",
            "-static",
            "-O",
            "ReleaseSafe",
            "-fPIC",
            "-fcompiler-rt",
            &format!("-femit-bin={}", output.join("libxy_gpui_core.a").display()),
            "--dep",
            "view_config",
            "--dep",
            "surface",
            "--dep",
            "viewport_layout",
            "--dep",
            "pixel_transfer",
            "--dep",
            "rotated_surface",
            "--dep",
            "canvas",
            "-Mroot=src/gpui_host.zig",
            "-Msurface=src/graphics/surface.zig",
            "--dep",
            "view_config",
            "-Mviewport_layout=src/graphics/viewport_layout.zig",
            "-Mview_config=src/xy/view_config.zig",
            "-Mpixel_transfer=src/graphics/pixel_transfer.zig",
            "--dep",
            "surface",
            "-Mrotated_surface=src/graphics/rotated_surface.zig",
            "--dep",
            "surface",
            "-Mcanvas=src/graphics/canvas.zig",
        ])
        .status()
        .expect("compile the shared Zig renderer");
    assert!(status.success(), "shared Zig renderer build failed");
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=xy_gpui_core");
}
