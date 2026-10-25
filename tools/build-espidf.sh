#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$repo_root/build/espidf"

if [ ! -x "$repo_root/.tools/zig-0.17.0/zig" ]; then
    sh "$repo_root/tools/bootstrap-zig.sh" >/dev/null
fi

if [ -n "${NIHOS_IDF_PATH:-}" ]; then
    idf_path=$NIHOS_IDF_PATH
elif [ -n "${IDF_PATH:-}" ]; then
    idf_path=$IDF_PATH
elif [ -d "${HOME}/esp32/esp-idf-v5.4.4" ]; then
    idf_path="${HOME}/esp32/esp-idf-v5.4.4"
elif [ -d "${HOME}/esp/esp-idf" ]; then
    idf_path="${HOME}/esp/esp-idf"
else
    echo "ESP-IDF not found; set NIHOS_IDF_PATH" >&2
    exit 1
fi

if [ ! -f "$idf_path/export.sh" ]; then
    echo "invalid ESP-IDF path: $idf_path" >&2
    exit 1
fi

if ! command -v idf.py >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$idf_path/export.sh" >/dev/null
fi

mkdir -p "$build_dir"
cd "$repo_root"
exec idf.py -B "$build_dir" -D "SDKCONFIG=$build_dir/sdkconfig" build "$@"
