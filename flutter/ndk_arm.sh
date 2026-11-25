#!/usr/bin/env bash
# Build librustdesk.so for Android armeabi-v7a.
#
# Mirrors ndk_arm64.sh: on macOS hosts, libsodium-sys's autoconf falls back to
# Darwin ranlib, producing an empty libsodium.a; force NDK llvm-ar/ranlib and
# repair the archive before relinking.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=armv7-linux-androideabi
PROFILE=release
FEATURES=flutter,hwcodec

if [[ -z "${ANDROID_NDK_HOME:-}" && -z "${ANDROID_NDK_ROOT:-}" ]]; then
	echo "ERROR: set ANDROID_NDK_HOME (or ANDROID_NDK_ROOT)" >&2
	exit 1
fi
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_NDK_ROOT}"
export ANDROID_NDK_HOME ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"

case "$(uname -s)-$(uname -m)" in
Darwin-arm64 | Darwin-aarch64) NDK_HOST=darwin-x86_64 ;; # NDK still ships darwin-x86_64
Darwin-*) NDK_HOST=darwin-x86_64 ;;
Linux-x86_64) NDK_HOST=linux-x86_64 ;;
Linux-aarch64 | Linux-arm64) NDK_HOST=linux-aarch64 ;;
*)
	echo "ERROR: unsupported host $(uname -s)-$(uname -m)" >&2
	exit 1
	;;
esac

NDK_PREBUILT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST"
NDK_BIN="$NDK_PREBUILT/bin"
NDK_SYSROOT="$NDK_PREBUILT/sysroot"
if [[ ! -x "$NDK_BIN/llvm-ar" || ! -x "$NDK_BIN/llvm-ranlib" ]]; then
	echo "ERROR: NDK llvm-ar/llvm-ranlib not found under $NDK_BIN" >&2
	exit 1
fi

TOOL_ALIAS="$(mktemp -d "${TMPDIR:-/tmp}/ndk-armv7-tools.XXXXXX")"
cleanup() { rm -rf "$TOOL_ALIAS"; }
trap cleanup EXIT
ln -sfn "$NDK_BIN/llvm-ar" "$TOOL_ALIAS/arm-linux-androideabi-ar"
ln -sfn "$NDK_BIN/llvm-ranlib" "$TOOL_ALIAS/arm-linux-androideabi-ranlib"
ln -sfn "$NDK_BIN/llvm-nm" "$TOOL_ALIAS/arm-linux-androideabi-nm"
ln -sfn "$NDK_BIN/llvm-ar" "$TOOL_ALIAS/ar"
ln -sfn "$NDK_BIN/llvm-ranlib" "$TOOL_ALIAS/ranlib"
ln -sfn "$NDK_BIN/llvm-nm" "$TOOL_ALIAS/nm"
export PATH="$TOOL_ALIAS:$NDK_BIN:$PATH"
export AR="$NDK_BIN/llvm-ar"
export RANLIB="$NDK_BIN/llvm-ranlib"
export NM="$NDK_BIN/llvm-nm"

# bindgen on macOS must use NDK headers (host Xcode sysroot is incomplete).
if [[ "$(uname -s)" == "Darwin" ]]; then
	BINDGEN_ARGS="--sysroot=${NDK_SYSROOT} --target=armv7a-linux-androideabi21 -I${NDK_SYSROOT}/usr/include -I${NDK_SYSROOT}/usr/include/armv7a-linux-androideabi"
	export BINDGEN_EXTRA_CLANG_ARGS="$BINDGEN_ARGS"
	export BINDGEN_EXTRA_CLANG_ARGS_armv7_linux_androideabi="$BINDGEN_ARGS"
fi

cd "$ROOT"

cargo ndk --platform 21 --target "$TARGET" build --locked --"$PROFILE" --features "$FEATURES"

SO="$ROOT/target/$TARGET/$PROFILE/liblibrustdesk.so"
if [[ ! -f "$SO" ]]; then
	echo "ERROR: missing $SO" >&2
	exit 1
fi

undef_sodium() {
	"$NM" -D "$SO" 2>/dev/null | awk '/ U (sodium_|crypto_|randombytes_)/ {print}' | wc -l | tr -d ' '
}

count="$(undef_sodium)"
if [[ "$count" == "0" ]]; then
	echo "OK: $SO (sodium symbols resolved)"
	exit 0
fi

echo "WARN: $count undefined sodium/crypto symbols in $SO; repairing libsodium.a and relinking..."

build_out=""
newest=0
while IFS= read -r d; do
	[[ -d "$d" ]] || continue
	if [[ "$(uname -s)" == "Darwin" ]]; then
		m="$(stat -f '%m' "$d")"
	else
		m="$(stat -c '%Y' "$d")"
	fi
	if [[ "$m" -ge "$newest" ]]; then
		newest="$m"
		build_out="$d"
	fi
done < <(find "$ROOT/target/$TARGET/$PROFILE/build" -path '*/libsodium-sys-*/out/installed/lib' -type d 2>/dev/null)

if [[ -z "$build_out" ]]; then
	echo "ERROR: libsodium-sys out/installed/lib not found" >&2
	exit 1
fi

SRC_LIBSODIUM="$(dirname "$(dirname "$build_out")")/source/libsodium/src/libsodium"
LIBSOD_A="$build_out/libsodium.a"
OBJFILE="$(mktemp)"
find "$SRC_LIBSODIUM" -name 'libsodium_la-*.o' | sort >"$OBJFILE"
obj_count="$(wc -l <"$OBJFILE" | tr -d ' ')"
if [[ "$obj_count" -lt 1 ]]; then
	echo "ERROR: no libsodium_la-*.o under $SRC_LIBSODIUM" >&2
	exit 1
fi

"$AR" rcs "$LIBSOD_A" @"$OBJFILE"
echo "INFO: rebuilt $LIBSOD_A from $obj_count objects ($(wc -c <"$LIBSOD_A" | tr -d ' ') bytes)"
rm -f "$OBJFILE"

export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,--whole-archive -C link-arg=${LIBSOD_A} -C link-arg=-Wl,--no-whole-archive"
cargo ndk --platform 21 --target "$TARGET" build --locked --"$PROFILE" --features "$FEATURES"

count="$(undef_sodium)"
if [[ "$count" != "0" ]]; then
	echo "ERROR: still $count undefined sodium/crypto symbols after relink" >&2
	exit 1
fi
echo "OK: $SO (sodium symbols resolved after repair)"
