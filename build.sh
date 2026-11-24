#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

KSU_DEV=e5f5ec998de88b9fc43c62cff8f7ae12d3f4800a
KSU_STABLE=v3.4.0-legacy
DEFCONFIG=vendor/spes-perf_defconfig
AK3_REPO=https://github.com/osm0sis/AnyKernel3.git
AK3_REF=41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1

JOBS=$(nproc)
BOOT_IMG=""
OTA_ZIP=""
MAKE_ZIP=0
CLEAN=0
VARIANTS=()

usage() {
    cat <<EOF
Uso: ./build.sh [dev|stable|all] [opciones]

  -b, --boot IMG   boot.img base de la ROM para generar boot-<versión>.img
  -o, --ota ZIP    sacar el boot.img base de una OTA (payload.bin)
  -z, --zip        generar zip AnyKernel3
  -j, --jobs N     trabajos de make (por defecto: $JOBS)
  -c, --clean      compilar desde cero
  -h, --help       esta ayuda

Variante por defecto: dev. Salida en out/release/<variante>/
EOF
}

die() { echo "error: $*" >&2; exit 1; }
msg() { echo -e "\e[1;32m==>\e[0m $*"; }

while [ $# -gt 0 ]; do
    case $1 in
        dev|stable) VARIANTS+=("$1") ;;
        all) VARIANTS+=(dev stable) ;;
        -b|--boot) BOOT_IMG=$(realpath "${2:?falta el archivo}"); shift ;;
        -o|--ota) OTA_ZIP=$(realpath "${2:?falta el archivo}"); shift ;;
        -z|--zip) MAKE_ZIP=1 ;;
        -j|--jobs) JOBS=${2:?falta el número}; shift ;;
        -c|--clean) CLEAN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "opción desconocida: $1" ;;
    esac
    shift
done
[ ${#VARIANTS[@]} -gt 0 ] || VARIANTS=(dev)

for tool in clang ld.lld llvm-ar bc git python3; do
    command -v "$tool" >/dev/null || die "falta $tool"
done
[ $MAKE_ZIP = 0 ] || command -v zip >/dev/null || die "falta zip"
[ -e KernelSU-Next/kernel/Kconfig ] || die "submódulo KernelSU-Next vacío: git submodule update --init"

MAKE_ARGS=(ARCH=arm64 LLVM=1)
ssl_major=$(pkg-config --modversion libcrypto 2>/dev/null | cut -d. -f1 || true)
if [ "${ssl_major:-0}" -ge 4 ]; then
    [ -d /usr/lib/openssl-3 ] || die "OpenSSL $ssl_major no tiene ENGINE (scripts/extract-cert): instala openssl-3"
    export PKG_CONFIG_PATH=/usr/lib/openssl-3/pkgconfig
    MAKE_ARGS+=(HOSTLDFLAGS=-Wl,-rpath,/usr/lib/openssl-3)
fi

if [ -n "$OTA_ZIP" ]; then
    msg "boot.img base desde $(basename "$OTA_ZIP")"
    python3 -I build/payload_extract.py "$OTA_ZIP" out/base boot
    BOOT_IMG=$ROOT/out/base/boot.img
fi
[ -z "$BOOT_IMG" ] || [ -f "$BOOT_IMG" ] || die "no existe $BOOT_IMG"

ksu_orig=$(git -C KernelSU-Next rev-parse HEAD)
trap 'git -C "$ROOT/KernelSU-Next" checkout -q "$ksu_orig"' EXIT

localversion=$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"/\1/p' "arch/arm64/configs/$DEFCONFIG")

ksu_checkout() {
    git -C KernelSU-Next cat-file -e "$1^{commit}" 2>/dev/null \
        || git -C KernelSU-Next fetch -q origin legacy --tags
    git -C KernelSU-Next checkout -q "$1"
}

ak3_zip() {
    local name=$1 dest=$2 ak=$ROOT/out/AnyKernel3 stage
    if [ ! -d "$ak/.git" ]; then
        git clone -q "$AK3_REPO" "$ak"
    fi
    git -C "$ak" cat-file -e "$AK3_REF^{commit}" 2>/dev/null || git -C "$ak" fetch -q origin
    git -C "$ak" checkout -q "$AK3_REF"
    stage=$(mktemp -d)
    cp -r "$ak"/{META-INF,tools,modules,patch,ramdisk,LICENSE} "$stage"/
    cp build/anykernel.sh "$dest/Image.gz" "$stage"/
    local zipname="${localversion#-}-$name-spes-$(date +%Y%m%d).zip"
    rm -f "$dest/$zipname"
    (cd "$stage" && zip -qr9 "$dest/$zipname" . -x '.git*' 'README.md')
    rm -rf "$stage"
    echo "    $dest/$zipname"
}

build_variant() {
    local name=$1 ref=$2 out=$ROOT/out/$1 dest=$ROOT/out/release/$1 rel
    msg "$name: KernelSU-Next $ref"
    ksu_checkout "$ref"
    [ $CLEAN = 0 ] || rm -rf "$out"
    mkdir -p "$out" "$dest"

    make -s O="$out" "${MAKE_ARGS[@]}" "$DEFCONFIG"
    grep -q '^CONFIG_KSU=y' "$out/.config" || die "$name: CONFIG_KSU quedó desactivado"
    grep -q '^CONFIG_KSU_MANUAL_HOOK=y' "$out/.config" || die "$name: CONFIG_KSU_MANUAL_HOOK quedó desactivado"

    if ! make O="$out" "${MAKE_ARGS[@]}" -j"$JOBS" LOCALVERSION="-$name" Image.gz dtbs > "$out/build.log" 2>&1; then
        grep -E "error|Error" "$out/build.log" | head -20 >&2
        die "$name: falló la compilación (log: $out/build.log)"
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
msg "listo: out/release/"
