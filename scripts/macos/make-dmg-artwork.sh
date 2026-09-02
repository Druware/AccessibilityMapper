#!/bin/bash
#
# make-dmg-artwork.sh <output-dir>
#
# Generates the two artwork files the "Accessibility Mapper" DMG packaging step needs:
#
#   <output-dir>/background.tiff   multi-representation HiDPI TIFF (1x + 2x)
#   <output-dir>/VolumeIcon.icns   volume icon built from the app icon PNGs
#
# Only macOS built-in tools are used: swift, iconutil and tiffutil.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly BACKGROUND_SWIFT="${SCRIPT_DIR}/DMGBackground.swift"
readonly ICON_SRC_DIR="${REPO_ROOT}/Apple/Sources/AccessibilityMapper/Assets.xcassets/AppIcon.appiconset"

die() {
    printf 'make-dmg-artwork: error: %s\n' "$*" >&2
    exit 1
}

# --- Arguments -------------------------------------------------------------

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <output-dir>\n' "$(basename -- "$0")" >&2
    exit 2
fi

readonly OUTPUT_DIR="$1"

mkdir -p -- "${OUTPUT_DIR}" || die "could not create output directory '${OUTPUT_DIR}'"
OUTPUT_DIR_ABS="$(cd -- "${OUTPUT_DIR}" && pwd)" || die "output directory '${OUTPUT_DIR}' is not accessible"
readonly OUTPUT_DIR_ABS

readonly BACKGROUND_TIFF="${OUTPUT_DIR_ABS}/background.tiff"
readonly VOLUME_ICNS="${OUTPUT_DIR_ABS}/VolumeIcon.icns"

# --- Preflight -------------------------------------------------------------

for tool in swift iconutil tiffutil sips; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool '${tool}' was not found on PATH"
done

[[ -f "${BACKGROUND_SWIFT}" ]] || die "missing background renderer '${BACKGROUND_SWIFT}'"
[[ -d "${ICON_SRC_DIR}" ]] || die "missing app icon source directory '${ICON_SRC_DIR}'"

# --- Temp workspace --------------------------------------------------------

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dmg-artwork.XXXXXX")" || die "could not create a temporary directory"
readonly WORK_DIR
cleanup() { rm -rf -- "${WORK_DIR}"; }
trap cleanup EXIT

# --- Volume icon -----------------------------------------------------------

# The AccessibilityMapper icon assets follow the standard Apple iconset naming
# convention, so each iconset entry maps directly to the same-named source file.
readonly ICONSET_MAP=(
    "icon_16x16.png:icon_16x16"
    "icon_16x16@2x.png:icon_16x16@2x"
    "icon_32x32.png:icon_32x32"
    "icon_32x32@2x.png:icon_32x32@2x"
    "icon_128x128.png:icon_128x128"
    "icon_128x128@2x.png:icon_128x128@2x"
    "icon_256x256.png:icon_256x256"
    "icon_256x256@2x.png:icon_256x256@2x"
    "icon_512x512.png:icon_512x512"
    "icon_512x512@2x.png:icon_512x512@2x"
)

build_volume_icon() {
    local iconset_dir="${WORK_DIR}/VolumeIcon.iconset"
    mkdir -p -- "${iconset_dir}" || die "could not create the temporary iconset directory"

    local entry dest src src_path
    for entry in "${ICONSET_MAP[@]}"; do
        dest="${entry%%:*}"
        src="${entry##*:}"
        src_path="${ICON_SRC_DIR}/${src}.png"
        [[ -f "${src_path}" ]] || die "missing app icon source '${src_path}'"
        cp -- "${src_path}" "${iconset_dir}/${dest}" \
            || die "could not copy '${src_path}' into the iconset"
    done

    rm -f -- "${VOLUME_ICNS}"
    iconutil --convert icns --output "${VOLUME_ICNS}" "${iconset_dir}" \
        || die "iconutil failed to build '${VOLUME_ICNS}'"
    [[ -s "${VOLUME_ICNS}" ]] || die "iconutil produced an empty '${VOLUME_ICNS}'"
}

# --- Background ------------------------------------------------------------

readonly CANVAS_WIDTH=660
readonly CANVAS_HEIGHT=520

# render_background <out.png> <scale>
render_background() {
    local out="$1" scale="$2"
    local expected_w=$(( CANVAS_WIDTH * scale ))
    local expected_h=$(( CANVAS_HEIGHT * scale ))

    swift "${BACKGROUND_SWIFT}" "${out}" "${scale}" \
        || die "rendering the ${scale}x background failed"
    [[ -s "${out}" ]] || die "the ${scale}x background render produced no output"

    local actual_w actual_h
    actual_w="$(sips -g pixelWidth "${out}" | awk '/pixelWidth/ { print $2 }')"
    actual_h="$(sips -g pixelHeight "${out}" | awk '/pixelHeight/ { print $2 }')"
    if [[ "${actual_w}" != "${expected_w}" || "${actual_h}" != "${expected_h}" ]]; then
        die "the ${scale}x background is ${actual_w}x${actual_h}, expected ${expected_w}x${expected_h}"
    fi
}

build_background() {
    local png_1x="${WORK_DIR}/background-1x.png"
    local png_2x="${WORK_DIR}/background-2x.png"

    render_background "${png_1x}" 1
    render_background "${png_2x}" 2

    rm -f -- "${BACKGROUND_TIFF}"

    # -cathidpi is the historical spelling; tiffutil v350 (macOS 26/27) renamed it
    # to -cathidpicheck. Try the documented name first, then the current one.
    local flag combined=0
    for flag in -cathidpi -cathidpicheck; do
        if tiffutil "${flag}" "${png_1x}" "${png_2x}" -out "${BACKGROUND_TIFF}" >/dev/null 2>&1; then
            combined=1
            break
        fi
    done
    (( combined == 1 )) || die "tiffutil could not combine the 1x and 2x renders into '${BACKGROUND_TIFF}' (tried -cathidpi and -cathidpicheck)"
    [[ -s "${BACKGROUND_TIFF}" ]] || die "tiffutil produced an empty '${BACKGROUND_TIFF}'"

    local reps
    reps="$(tiffutil -info "${BACKGROUND_TIFF}" 2>/dev/null | grep -c 'Image Width' || true)"
    [[ "${reps}" == "2" ]] || die "'${BACKGROUND_TIFF}' has ${reps} representation(s), expected 2"
}

# --- Run -------------------------------------------------------------------

build_background
build_volume_icon

# --- Summary ---------------------------------------------------------------

summarize() {
    local path="$1" detail="$2" bytes
    bytes="$(stat -f %z -- "${path}")"
    printf '%s  (%s bytes, %s)\n' "${path}" "${bytes}" "${detail}"
}

summarize "${BACKGROUND_TIFF}" "HiDPI TIFF, ${CANVAS_WIDTH}x${CANVAS_HEIGHT} @1x + @2x"
summarize "${VOLUME_ICNS}" "ICNS, 16-512pt with @2x variants"
