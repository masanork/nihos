#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
build_dir="$repo_root/build/store-file"
mkdir -p "$build_dir"
"$zig" fmt --check "$repo_root/probes/store/file_probe.zig"
"$zig" build-exe -O safe --dep cow_model --dep file_media \
    -Mroot="$repo_root/probes/store/file_probe.zig" \
    -Mcow_model="$repo_root/src/storage/cow_model.zig" \
    -Mfile_media="$repo_root/src/storage/file_media.zig" \
    -femit-bin="$build_dir/file-probe"
result_dir=$(mktemp -d "$build_dir/process.XXXXXX")
python3 "$repo_root/tools/store_file_probe.py" "$build_dir/file-probe" "$result_dir"
