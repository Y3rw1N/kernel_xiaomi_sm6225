#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

DEFCONFIG=${DEFCONFIG:-vendor/spes-perf_defconfig}
AK3_REPO=${AK3_REPO:-https://github.com/osm0sis/AnyKernel3.git}
AK3_REF=${AK3_REF:-41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1}

JOBS=$(nproc)
BOOT_IMG=""
OTA_ZIP=""
MAKE_ZIP=0
CLEAN=0
UPDATE=0
VARIANTS=()

usage() {
    cat <<EOF
Usage: ./build.sh [dev|stable|all] [options]

  -b, --boot IMG   stock boot.img to repack as boot-<release>.img
  -o, --ota ZIP    take the stock boot.img from an OTA zip (payload.bin)
  -z, --zip        build an AnyKernel3 zip
  -u, --update     fetch new KernelSU-Next legacy commits and tags first
  -j, --jobs N     make jobs (default: $JOBS)
  -c, --clean      build from scratch
  -h, --help       show this help

Variants (default: dev):
  dev      KernelSU-Next commit recorded in this repo (or \$KSU_DEV)
  stable   newest v*-legacy tag (or \$KSU_STABLE)

Output: out/release/<variant>/
Overrides: KSU_DEV, KSU_STABLE, DEFCONFIG, AK3_REPO, AK3_REF
EOF
}

die() { echo "error: $*" >&2; exit 1; }
msg() { echo -e "\e[1;32m==>\e[0m $*"; }

while [ $# -gt 0 ]; do
    case $1 in
        dev|stable) VARIANTS+=("$1") ;;
        all) VARIANTS+=(dev stable) ;;
        -b|--boot) BOOT_IMG=$(realpath "${2:?missing file}"); shift ;;
        -o|--ota) OTA_ZIP=$(realpath "${2:?missing file}"); shift ;;
        -z|--zip) MAKE_ZIP=1 ;;
        -u|--update) UPDATE=1 ;;
        -j|--jobs) JOBS=${2:?missing number}; shift ;;
        -c|--clean) CLEAN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done
[ ${#VARIANTS[@]} -gt 0 ] || VARIANTS=(dev)

for tool in clang ld.lld llvm-ar bc git python3; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
[ $MAKE_ZIP = 0 ] || command -v zip >/dev/null || die "zip not found"
[ -e KernelSU-Next/kernel/Kconfig ] || die "KernelSU-Next submodule is empty: git submodule update --init"

MAKE_ARGS=(ARCH=arm64 LLVM=1)
ssl_major=$(pkg-config --modversion libcrypto 2>/dev/null | cut -d. -f1 || true)
if [ "${ssl_major:-0}" -ge 4 ]; then
    [ -d /usr/lib/openssl-3 ] || die "OpenSSL $ssl_major dropped ENGINE (scripts/extract-cert): install openssl-3"
    export PKG_CONFIG_PATH=/usr/lib/openssl-3/pkgconfig
    MAKE_ARGS+=(HOSTLDFLAGS=-Wl,-rpath,/usr/lib/openssl-3)
fi

if [ $UPDATE = 1 ]; then
    msg "fetching KernelSU-Next legacy"
    git -C KernelSU-Next fetch -q origin legacy --tags
    echo "    legacy HEAD: $(git -C KernelSU-Next rev-parse --short FETCH_HEAD)"
fi

KSU_DEV=${KSU_DEV:-$(git ls-tree HEAD KernelSU-Next | awk '{print $3}')}
KSU_STABLE=${KSU_STABLE:-$(git -C KernelSU-Next tag -l 'v*-legacy' --sort=-v:refname | head -1)}
[ -n "$KSU_DEV" ] || die "no KernelSU-Next commit recorded in HEAD"
[ -n "$KSU_STABLE" ] || die "no v*-legacy tag found (try --update)"

if [ -n "$OTA_ZIP" ]; then
    msg "stock boot.img from $(basename "$OTA_ZIP")"
    python3 -I build/payload_extract.py "$OTA_ZIP" out/base boot
    BOOT_IMG=$ROOT/out/base/boot.img
fi
[ -z "$BOOT_IMG" ] || [ -f "$BOOT_IMG" ] || die "$BOOT_IMG does not exist"

ksu_orig=$(git -C KernelSU-Next rev-parse HEAD)
trap 'git -C "$ROOT/KernelSU-Next" checkout -q "$ksu_orig"' EXIT

localversion=$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"/\1/p' "arch/arm64/configs/$DEFCONFIG")

ksu_checkout() {
    git -C KernelSU-Next cat-file -e "$1^{commit}" 2>/dev/null \
        || git -C KernelSU-Next fetch -q origin legacy --tags
    git -C KernelSU-Next checkout -q "$1"
}

ak3_zip() {
    local name=$1 dest=$2 ak=$ROOT/out/AnyKernel3 stage zipname
    [ -d "$ak/.git" ] || git clone -q "$AK3_REPO" "$ak"
    git -C "$ak" cat-file -e "$AK3_REF^{commit}" 2>/dev/null || git -C "$ak" fetch -q origin
    git -C "$ak" checkout -q "$AK3_REF"
    stage=$(mktemp -d)
    cp -r "$ak"/{META-INF,tools,modules,patch,ramdisk,LICENSE} "$stage"/
    cp build/anykernel.sh "$dest/Image.gz" "$stage"/
    zipname="${localversion#-}-$name-spes-$(date +%Y%m%d).zip"
    rm -f "$dest/$zipname"
    (cd "$stage" && zip -qr9 "$dest/$zipname" . -x '.git*' 'README.md')
    rm -rf "$stage"
    echo "    $dest/$zipname"
}

build_variant() {
    local name=$1 ref=$2 out=$ROOT/out/$1 dest=$ROOT/out/release/$1 rel
    ksu_checkout "$ref"
    msg "$name: KernelSU-Next $(git -C KernelSU-Next describe --tags --always)"
    [ $CLEAN = 0 ] || rm -rf "$out"
    mkdir -p "$out" "$dest"

    make -s O="$out" "${MAKE_ARGS[@]}" "$DEFCONFIG"
    grep -q '^CONFIG_KSU=y' "$out/.config" || die "$name: CONFIG_KSU got disabled"
    grep -q '^CONFIG_KSU_MANUAL_HOOK=y' "$out/.config" || die "$name: CONFIG_KSU_MANUAL_HOOK got disabled"

    if ! make O="$out" "${MAKE_ARGS[@]}" -j"$JOBS" LOCALVERSION="-$name" Image.gz dtbs > "$out/build.log" 2>&1; then
        grep -E "error|Error" "$out/build.log" | head -20 >&2
        die "$name: build failed (log: $out/build.log)"
    fi

    rel=$(cat "$out/include/config/kernel.release")
    cp "$out/arch/arm64/boot/Image.gz" "$dest/Image.gz"
    echo "    $rel"
    if [ -n "$BOOT_IMG" ]; then
        python3 -I build/boot_swap_kernel.py "$BOOT_IMG" "$dest/Image.gz" "$dest/boot-$rel.img"
        echo "    $dest/boot-$rel.img"
    fi
    [ $MAKE_ZIP = 0 ] || ak3_zip "$name" "$dest"
}

for v in "${VARIANTS[@]}"; do
    case $v in
        dev) build_variant dev "$KSU_DEV" ;;
        stable) build_variant stable "$KSU_STABLE" ;;
    esac
done
msg "done: out/release/"
