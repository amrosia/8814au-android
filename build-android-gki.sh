#!/bin/sh
# build-android-gki.sh -- build this driver for an Android GKI kernel.
#
# Two phases:
#   ./build-android-gki.sh kernel-prepare   configure the reference kernel tree
#   ./build-android-gki.sh kernel-build     build vmlinux (-> vmlinux.symvers)
#   ./build-android-gki.sh module           build 8814au.ko against it
#
# The reference kernel build exists only to reproduce the device's symbol CRCs
# and headers. Nothing from it is installed on the device.
#
# See ANDROID-GKI.md for requirements, tested hardware and rationale.

set -eu

# ---------------------------------------------------------------- configuration
# kernel/common checkout at the device's exact commit
: "${KERN_SRC:=/path/to/kernel/common}"

# How to obtain the device's config: a file, or "adb" to pull /proc/config.gz
: "${DEVICE_CONFIG:=adb}"

# Exact kernel release string of the device ("uname -r"). The module's vermagic
# must match it. Pulled from adb when DEVICE_CONFIG=adb.
: "${KERNEL_RELEASE:=}"

# Toolchain (directories, PATH is assembled below)
: "${CLANG_DIR:?set CLANG_DIR to the clang 17 bin directory}"
: "${LLVM_BINUTILS_DIR:?set LLVM_BINUTILS_DIR to the LLVM binutils bin dir}" # ld.lld, llvm-ar, ...
: "${LLVM_DIR:=$LLVM_BINUTILS_DIR}"                                        # llvm-objdump/readelf
: "${BISON_DIR:=$(dirname "$(command -v bison 2>/dev/null || echo /usr/bin/bison)")}"
: "${FLEX_DIR:=$(dirname "$(command -v flex 2>/dev/null || echo /usr/bin/flex)")}"
: "${DTC_DIR:=$(dirname "$(command -v dtc 2>/dev/null || echo /usr/bin/dtc)")}"
: "${PAHOLE:=pahole}"

# Host-only libraries needed by scripts/sign-file and tools/bpf/resolve_btfids
: "${OPENSSL_DEV:=}"   ; : "${OPENSSL_LIB:=}"
: "${ELFUTILS_DEV:=}"  ; : "${ELFUTILS_LIB:=}"

JOBS=${JOBS:-$(nproc)}

# Extra ccflags for the module. CONFIG_NL80211_TESTMODE must match the vendor
# cfg80211 build or the cfg80211_ops layout is shifted (see ANDROID-GKI.md).
MODULE_KCFLAGS="-DCONFIG_NL80211_TESTMODE=1 -Wno-unknown-warning-option \
-Wno-error=incompatible-pointer-types \
-Wno-error=incompatible-pointer-types-discards-qualifiers -Wno-error=int-conversion"

DRV_DIR=$(cd "$(dirname "$0")" && pwd)

export PATH="$CLANG_DIR:$LLVM_BINUTILS_DIR:$LLVM_DIR:$BISON_DIR:$FLEX_DIR:$DTC_DIR:$PATH"

HOSTCFLAGS="-O2 -std=gnu11"
HOSTLDFLAGS=""
[ -n "$OPENSSL_DEV" ]  && HOSTCFLAGS="$HOSTCFLAGS -I$OPENSSL_DEV/include"
[ -n "$OPENSSL_LIB" ]  && HOSTLDFLAGS="$HOSTLDFLAGS -L$OPENSSL_LIB/lib -Wl,-rpath,$OPENSSL_LIB/lib"
[ -n "$ELFUTILS_DEV" ] && HOSTCFLAGS="$HOSTCFLAGS -I$ELFUTILS_DEV/include"
[ -n "$ELFUTILS_LIB" ] && HOSTLDFLAGS="$HOSTLDFLAGS -L$ELFUTILS_LIB/lib -Wl,-rpath,$ELFUTILS_LIB/lib"

kbuild() {   # kbuild <make args...>
	make -C "$KERN_SRC" ARCH=arm64 LLVM=1 \
		HOSTCC=gcc HOSTCXX=g++ HOSTLD=ld HOSTAR=ar \
		HOSTCFLAGS="$HOSTCFLAGS" HOSTLDFLAGS="$HOSTLDFLAGS" \
		PAHOLE="$PAHOLE" -j"$JOBS" "$@"
}

get_config() {
	if [ "$DEVICE_CONFIG" = adb ]; then
		if [ -z "$KERNEL_RELEASE" ]; then
			KERNEL_RELEASE=$(adb shell uname -r | tr -d '\r')
		fi
		adb shell 'su -c "zcat /proc/config.gz"' > "$KERN_SRC/.config"
	else
		cp "$DEVICE_CONFIG" "$KERN_SRC/.config"
		[ -n "$KERNEL_RELEASE" ] || {
			echo "KERNEL_RELEASE must be set when DEVICE_CONFIG is a file" >&2
			exit 1
		}
	fi
	echo "device kernel release: $KERNEL_RELEASE"
}

# ---------------------------------------------------------------------- phases
case "${1:-}" in
kernel-prepare)
	# Verbatim device config. Only these three build-time knobs are adjusted;
	# none of them changes symbol CRCs. DEBUG_INFO/BTF are intentionally kept.
	get_config
	sed -i \
		-e 's/^CONFIG_TRIM_UNUSED_KSYMS=y/# CONFIG_TRIM_UNUSED_KSYMS is not set/' \
		-e 's/^CONFIG_WERROR=y/# CONFIG_WERROR is not set/' \
		"$KERN_SRC/.config"
	# PAHOLE_VERSION gates CONFIG_DEBUG_INFO_BTF_MODULES; it must stay enabled
	# because struct module (and therefore module_layout) depends on it.
	pv=$("$PAHOLE" --version 2>/dev/null | sed -n 's/^v\?\([0-9]*\)\.\([0-9]*\).*/\1\2/p' | head -1)
	[ -n "$pv" ] && sed -i "s/^CONFIG_PAHOLE_VERSION=.*/CONFIG_PAHOLE_VERSION=$pv/" "$KERN_SRC/.config"
	kbuild olddefconfig
	grep -E '^CONFIG_(DEBUG_INFO_BTF_MODULES|MODVERSIONS|CFI_CLANG)=' "$KERN_SRC/.config"
	echo "now run: $0 kernel-build"
	;;

kernel-build)
	kbuild vmlinux            # produces $KERN_SRC/vmlinux.symvers
	kbuild modules_prepare    # produces scripts/module.lds
	# Force the device's exact release string into the vermagic.
	printf '%s\n' "$KERNEL_RELEASE" > "$KERN_SRC/include/config/kernel.release"
	sed -i "s|^#define UTS_RELEASE .*|#define UTS_RELEASE \"$KERNEL_RELEASE\"|" \
		"$KERN_SRC/include/generated/utsrelease.h"
	# Module.symvers must contain the kernel exports; append the exports of the
	# vendor modules that live on the device (cfg80211, ...) if you extracted them.
	cp "$KERN_SRC/vmlinux.symvers" "$KERN_SRC/Module.symvers"
	grep -P '^0x\S+\tmodule_layout\t' "$KERN_SRC/Module.symvers" || true
	echo "now run: $0 module"
	;;

module)
	[ -f "$KERN_SRC/Module.symvers" ] || { echo "run kernel-build first" >&2; exit 1; }
	make -C "$KERN_SRC" M="$DRV_DIR" ARCH=arm64 LLVM=1 \
		CONFIG_RTL8814AU=m KCFLAGS="$MODULE_KCFLAGS" \
		HOSTCC=gcc HOSTCXX=g++ HOSTLD=ld HOSTAR=ar \
		HOSTCFLAGS="$HOSTCFLAGS" HOSTLDFLAGS="$HOSTLDFLAGS" \
		PAHOLE="$PAHOLE" -j"$JOBS" modules
	echo
	echo "built: $DRV_DIR/8814au.ko"
	echo "verify before installing:"
	echo "  strings $DRV_DIR/8814au.ko | grep '^vermagic='   # must equal: $KERNEL_RELEASE ..."
	echo "  llvm-nm $DRV_DIR/8814au.ko | grep __kcfi_typeid_rtw_xmit_entry"
	echo "  llvm-nm --undefined-only $DRV_DIR/8814au.ko     # nothing the kernel lacks"
	;;

*)
	sed -n '2,20p' "$0"
	exit 1
	;;
esac
