#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
build_dir="$repo_root/build/store-service"
mkdir -p "$build_dir"
"$zig" fmt --check "$repo_root/probes/store/service_probe.zig"
"$zig" build-exe -O safe --dep checkpoint_service --dep file_media --dep spsc_ring \
    -Mroot="$repo_root/probes/store/service_probe.zig" \
    -Mcheckpoint_service="$repo_root/src/storage/checkpoint_service.zig" \
    -Mfile_media="$repo_root/src/storage/file_media.zig" \
    -Mspsc_ring="$repo_root/src/kernel/spsc_ring.zig" \
    -femit-bin="$build_dir/service-probe"
result_dir=$(mktemp -d "$build_dir/process.XXXXXX")
python3 "$repo_root/tools/checkpoint_service_probe.py" "$build_dir/service-probe" "$result_dir"
