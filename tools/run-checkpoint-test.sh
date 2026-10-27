#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
profile_cache=${NIHOS_STORE_LEAF_CACHE_PAGES:-128}
case "$profile_cache" in 0|64|128) ;; *) echo "unsupported leaf cache profile: $profile_cache" >&2; exit 1 ;; esac
build_dir="$repo_root/build/checkpoint/cache-$profile_cache"
mkdir -p "$build_dir"
printf 'pub const leaf_cache_pages: u16 = %s;\n' "$profile_cache" > "$build_dir/cache-options.zig"
"$zig" fmt --check "$repo_root/probes/store/checkpoint_probe.zig"
"$zig" build-exe -O safe --dep checkpoint_model --dep file_media --dep cache_options \
    -Mroot="$repo_root/probes/store/checkpoint_probe.zig" \
    -Mcheckpoint_model="$repo_root/src/storage/checkpoint_model.zig" \
    -Mfile_media="$repo_root/src/storage/file_media.zig" \
    -Mcache_options="$build_dir/cache-options.zig" \
    -femit-bin="$build_dir/checkpoint-probe"
result_dir=$(mktemp -d "$build_dir/process.XXXXXX")
python3 "$repo_root/tools/checkpoint_probe.py" "$build_dir/checkpoint-probe" "$result_dir"
