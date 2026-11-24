# Building and installing this driver on Android (GKI / kCFI kernels)

This fork of `morrownr/8814au` adds the changes needed to build and **load** the
RTL8814AU driver as an out-of-tree module on a modern Android "GKI" kernel
(`android14-6.1`) that is built with `CONFIG_CFI_CLANG`, `CONFIG_MODVERSIONS`
and `CONFIG_TRIM_UNUSED_KSYMS`.

Upstream builds unmodified on a normal desktop Linux kernel. Nothing here is an
upstream bug: every change exists because Android kernels are stricter than
desktop kernels about

* **kCFI** – the kernel checks the *exact type* of every indirect call target.
  A callback declared with a slightly different prototype (even `int` instead of
  an `enum` return type) traps and panics the device.
* **trimmed exports** – `CONFIG_TRIM_UNUSED_KSYMS` means the device kernel only
  exports the symbols in Google's KMI list. A few VFS helpers this driver used
  are simply not exported there.
* **module symbol versioning** – the module must be built against the *exact*
  kernel source + config of the device, otherwise CRCs differ and nothing loads.

---

## Tested on

| | |
|---|---|
| Device | **Lenovo TB321FU** (Legion Tab), Snapdragon 8 Gen 3, Android 16, Magisk root, SELinux enforcing |
| Kernel | `6.1.118-android14-11-g5ae0bfe2d916-ab12884444`, aarch64 |
| Kernel source | `kernel/common` @ `5ae0bfe2d916d23fc1041b4d228a7eb0e537ee42` (ACK `android14-6.1`) |
| `module_layout` CRC of that kernel | `0xea759d7f` |
| Adapter | **ALFA AWUS1900** – Realtek **RTL8814AU**, USB ID `0bda:8813` |
| Connection | USB-C port (dual-role dwc3) → **USB-C to USB-A OTG adapter** → adapter |
| Result | module loads, `wlan1` registers, `ifup` succeeds, nl80211 scan returns
>100 BSS on 2.4/5 GHz |

The RTL8814AU firmware is **embedded in the driver** (`hal/rtl8814a/hal8814a_fw.c`),
so no `rtl8814a_fw.bin` has to be installed in `/vendor/firmware` or `/lib/firmware`.

---

## Requirements

### Target device

* Root (Magisk is what was tested) – `insmod` needs `CAP_SYS_MODULE`.
* Kernel built with `CONFIG_MODULES=y`, `CONFIG_MODVERSIONS=y`, and
  `CONFIG_MODULE_SIG_FORCE` **not** set (unsigned modules then only taint the
  kernel). Verify:
  ```sh
  su -c 'zcat /proc/config.gz | grep -E "CONFIG_(MODULES|MODVERSIONS|CFI_CLANG|TRIM_UNUSED_KSYMS)=|MODULE_SIG_FORCE"'
  su -c 'cat /proc/sys/kernel/modules_disabled'   # must be 0
  ```
* A USB host-capable port and enough power: the AWUS1900 draws up to ~1 A.
  A **powered hub whose upstream is USB-C** is recommended for sustained load.
  Plain USB-A→C adapters are detected as `USB_DCP`/`BrickID` chargers and the
  port will never enter host mode — USB-C→USB-A **OTG** adapters (with the
  5.1 kΩ Rd) or C-to-C connections do work.

### Build host

* x86_64 Linux, ≥ 6 cores and ~10 GB free disk for the reference kernel build.
* **clang 17** with LLVM binutils (`ld.lld`, `llvm-ar`, `llvm-nm`,
  `llvm-objcopy`, `llvm-strip`, `llvm-readelf`).
  *Verified with clang 17.0.6; Android uses r487747c (17.0.2). The kCFI type
  hash algorithm is the same across 17.x, which is what matters.*
* `pahole` ≥ 1.19 (1.26 used) – required because the kernel has
  `CONFIG_DEBUG_INFO_BTF_MODULES`.
* `bison`, `flex`, `dtc`, `bc`, `perl`, `python3`, `openssl` (headers + lib),
  `elfutils`/libelf headers, `zlib`.
* A checkout of the device's **exact** `kernel/common` commit and the device's
  **exact** `/proc/config.gz`.

> Any kernel update (OTA) changes the ABI and requires re-doing the whole
> procedure with the new commit/config.

---

## Build

Everything is driven by `build-android-gki.sh`; set the paths at the top of the
script (clang, pahole, libelf/openssl prefixes, kernel tree) or export them.

```sh
# 1) reference kernel build -- only needed to obtain correct symbol CRCs
KERN_SRC=/path/to/kernel/common      # @ 5ae0bfe2d916 for the tested device
./build-android-gki.sh kernel-prepare # writes .config from the device's config
./build-android-gki.sh kernel-build   # ~10 min, produces vmlinux.symvers

# 2) driver module
./build-android-gki.sh module         # produces 8814au.ko
```

### Config deltas used for the reference build

The device config is used **verbatim**, except for these build-time-only changes
(they do not affect symbol CRCs):

| option | value | why |
|---|---|---|
| `CONFIG_DEBUG_INFO`, `CONFIG_DEBUG_INFO_BTF*` | **kept as on device** | `struct module` contains BTF fields; disabling them changes `module_layout` and the module will not load |
| `CONFIG_TRIM_UNUSED_KSYMS` | `n` | the reference build would need Google's private `abi_symbollist.raw` |
| `CONFIG_WERROR` | `n` | newer clang warns where the device's clang did not |
| `CONFIG_PAHOLE_VERSION` | value matching your pahole | must satisfy `PAHOLE_HAS_SPLIT_BTF` so `DEBUG_INFO_BTF_MODULES` stays enabled |

### Required module compile flag

```
-DCONFIG_NL80211_TESTMODE=1
```

The vendor-built `cfg80211.ko` on the tested device was compiled with
`CONFIG_NL80211_TESTMODE=y`, so its `struct cfg80211_ops` has two extra
members. Without this flag the driver's ops table is shifted by 16 bytes
relative to the kernel's view, which makes `wiphy_register()` fail with
`-EINVAL` (and produces bogus ops-pair warnings). Detect it on the device with:

```sh
llvm-nm /path/to/cfg80211.ko | grep nl80211_testmode_do
```

---

## Verify before installing

Do not skip these — they catch almost every "module won't load" failure without
having to reboot the tablet.

```sh
# 1) CRC cross-check against the vendor modules that are already on the device.
#    Extract __versions from cfg80211.ko/mac80211.ko and compare with
#    vmlinux.symvers; expect ZERO mismatches (402 symbols checked here).
# 2) module_layout must equal the running kernel's:
grep -P '^0x\S+\tmodule_layout\t' vmlinux.symvers     # 0xea759d7f on this device
# 3) kCFI type hash of the xmit callback must match ndo_start_xmit:
llvm-nm 8814au.ko | grep __kcfi_typeid_rtw_xmit_entry # 0x44e57e43 on this device
# 4) no symbol the kernel does not export:
llvm-nm --undefined-only 8814au.ko     # cross-check against __ksymtab_* in /proc/kallsyms
```

`module_layout` is the cheapest fingerprint: if it differs, the kernel tree,
config or `DEBUG_INFO`/BTF settings do not match and nothing else will work.

---

## Install on the device

```sh
adb push 8814au.ko /data/local/tmp/
adb shell su -c 'insmod /data/local/tmp/8814au.ko'
adb shell su -c 'dmesg | tail'          # expect: "RTW: module init ret=0"
adb shell su -c 'ip link show wlan1'    # interface + adapter MAC address
adb shell su -c 'ip link set wlan1 up'
```

The module is unsigned, so the kernel is tainted (`O` out-of-tree, `E`
unsigned) — expected.

### Do **not** force the USB role by hand

On the tested device, writing `host` to
`/sys/class/usb_role/a600000.ssusb-role-switch/role` **while nothing is
attached** NULL-derefs in Qualcomm's dwc3 host-notifier and panics. Plug the
adapter in and let UCSI switch the port to host automatically.

### Userspace

Android's `WifiManager`/Settings will **never** manage this interface: the
framework enumerates adapters through the vendor Wifi HAL, not through netdevs.
`wlan1` is a plain `cfg80211` netdev and needs your own userspace, e.g.:

* `wpa_supplicant` (`-Dnl80211`) + `dhcpcd` for association,
* a raw nl80211 client for scanning/config,
* or a Kali/NetHunter chroot for monitor mode (`tcpdump`, `airodump-ng`, …).

This fork contains Realtek's monitor-mode vif support, so monitor mode is
available without `mac80211`.

---

## What this fork changes, and why

| change | files | reason |
|---|---|---|
| tasklets registered through `void (*)(unsigned long)` wrappers | `hal/rtl8814a/usb/rtl8814au_xmit.c`, `hal/hal_hci/hal_usb.c`, `core/mesh/rtw_mesh.c` | upstream cast them `(void(*))` = `void(*)(void)`; kCFI expects `void(*)(unsigned long)` → panic on first TX/RX tasklet |
| URB completion callbacks use `void (*)(struct urb *)` | `os_dep/linux/usb_ops_linux.c`, `include/usb_ops_linux.h` | upstream uses the pre-4.14 `struct pt_regs *` signature → kCFI trap on every completion |
| `ndo_start_xmit` implementations return `netdev_tx_t` | `os_dep/linux/xmit_linux.c`, `os_dep/linux/mlme_linux.c`, `os_dep/linux/ioctl_cfg80211.c`, `include/xmit_osdep.h` | `int` vs `enum netdev_tx` compiles silently but has a different CFI hash → panic in `dev_hard_start_xmit` |
| removed 2-arg URB compat macros | `include/usb_ops_linux.h` | they rewrote the definitions themselves, recreating the wrong callback type |
| `cfg80211_ch_switch_{started_,}notify()` use the 6.9+ signatures | `os_dep/linux/ioctl_cfg80211.c` | ACK `android14-6.1` backported `punct_bitmap` into 6.1 |
| `wiphy->wowlan` stub not registered on 6.1+ | `os_dep/linux/ioctl_cfg80211.c` | `wiphy_register()` returns `-EINVAL` for wowlan support with no flags/patterns/tcp |
| in-kernel file helpers stubbed; `wpa_supplicant.conf` PNO parse disabled; `yield()` → `schedule()` | `os_dep/osdep_service.c`, `core/rtw_wlan_util.c` | `filp_open`, `kern_path`, `kernel_read`, `kernel_write`, `yield` are not exported by the GKI kernel; firmware is embedded and the cipher list falls back to its default |

The only diagnostics in the source are a handful of `RTWDBG*` `pr_info()` calls
in `ioctl_cfg80211.c` (`rtw_wiphy_register()`), left in from bring-up. They are
harmless and can be deleted; rebuild afterwards if you want a clean dmesg.

## Monitor mode and wifite

Monitor mode works, but only on the **main** interface: this driver enters
monitor state through `change_virtual_intf` → `Ndis802_11Monitor`. A separate
vif created with `iw dev wlan1 interface add mon0 type monitor` registers fine
but never receives frames, so point tools at `wlan1` itself.

```sh
# wlan1 must be down while the type is changed
ip link set wlan1 down
iw dev wlan1 set type monitor
ip link set wlan1 up
# optional: iw dev wlan1 set channel 6
```

`airmon-ng start wlan1` then reports "monitor mode already enabled" and does
not create a vif. Note that changing the type back (`iw dev wlan1 set type
managed`) works the same way.

minimal userspace stack used for testing (Android has no python/aircrack):

* Alpine arm64 minirootfs unpacked to `/data/local/tmp/alpine`, entered with
  `chroot` (bind-mount `/proc`, `/sys`, `/dev`),
* `apk add python3 py3-pip iw aircrack-ng wireless-tools iproute2 rfkill procps pciutils`,
* `wifite` from the upstream source tree (`Wifite.py`); the PyPI package
  currently installs a broken layout,
* wifite needs a TTY (`stty size`), so run it via a pty, e.g.
  `adb shell -t '...'` or a terminal emulator.

Observed result on the tested device: 79 targets / 28 clients on 2.4 GHz
(channels 1-13), radiotap frames from the driver. **Packet injection has not
been validated yet**, so deauth/handshake-capture attacks are untested; passive
discovery works.

## Known limitations

* Out-of-tree module ⇒ must be rebuilt for every kernel that changes the ABI.
* No Android framework integration (see *Userspace* above); per-app traffic
  routing needs root-level policy routing or a proxy.
* Station mode is validated. AP/P2P/monitor paths compile and register but have
  not been exercised here.
