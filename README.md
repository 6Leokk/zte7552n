# ZTE 7552N "changxing60" — OpenWrt on a 5G hotspot: the engineering record

A ZTE 7552N (P720S20) mobile 5G hotspot — board name **`changxing60`**, SoC Unisoc
T760 (UMS9620) — running **native OpenWrt 25.12 with a self-built 5.4.254 kernel,
coexisting with the stock Android on the same device**. No repartitioning, no
`boot_a` write, ever: Linux lives in the spare A/B slot (b), and 32 bytes of the
`misc` partition decide which system a reboot lands in.

This repository is the **docs + evidence** half of the project — dated
engineering logs with measurement receipts, device-state snapshots and rescue
tooling. The **port itself** (kernel build, rootfs overlays, init scripts, the
LuCI panels, host-side deploy tools) lives in the companion repo
**`changxing60-linux/`**, whose top-level layout (`boot/ kernel/ rootfs/ openwrt/
tools/ docs/`) mirrors the e5 reference projects. Docs here are written in
Chinese; they are a working log, not marketing — failures and retracted
conclusions are recorded with the same dates as the wins.

## Switching between the two systems

```
 slot a = stock Android          slot b = OpenWrt (this project)
   misc offset 2048: 32-byte bootloader_control picks the next reboot
   every successful OpenWrt boot re-arms slot b (tries=2) at ~70 s uptime
```

* **OpenWrt → Android — from the web admin.** LuCI → Services → **启动目标
  ("Boot target")**: arm Android behind a one-way-door confirmation, reboot is a
  separate button (arming must never silently reboot a device somebody is
  looking at). The page shows the misc bytes *read back after the write*, through
  the one script (`changxing60-next-boot`) that is allowed to touch them — CLI
  equivalent: `changxing60-next-boot android`.
* **Android → OpenWrt — from a PC over the USB cable.**
  `changxing60-linux/tools/changxing60-back-to-openwrt.sh`: re-stage the driver
  payload → fix 9 DTB bytes in `vendor_boot_b` → arm slot b → reboot → verify
  USB. If `boot_b` still holds the trial image it is a pure 32-byte misc write
  (`boot/android-boot-linux.sh`); reflashing `boot_b` is only for a overwritten
  slot — and `boot_a` is never a target.
* A Linux boot that fails to complete twice in a row falls back to Android by
  itself, so a broken kernel upgrade can't brick anything.

The full recipe, live hex dumps of the control block and the traps (e.g. the
"don't reboot twice inside the first 70 s" rule):
[`docs/changxing60/reboot-boot-slot.md`](docs/changxing60/reboot-boot-slot.md).

## What has been measured working

| | |
|---|---|
| Cellular WAN (5G NSA / LTE), IPv4 + IPv6 dual-stack | ✅ 4-stream 88–99 Mbps down measured at a client behind the device's NAT (87–114 Mbps on the device itself); per-flow ~20 Mbps is the client BDP, not the link |
| 5 GHz Wi-Fi AP (`changxing60`, ch36 VHT80) | ✅ real clients associate, get an address, surf; fixed BSSID (factory MAC pinned per boot) |
| Split LAN by design | ✅ USB gadget `br-lan` 192.168.77.1/24 = management only (no GW/DNS pushed); hotspot `br-wifi` 192.168.8.1/24 = gateway+DNS |
| Six LuCI panels (network / USB / SMS / voice / forwarding / boot target) | ✅ each backed by an rpcd ucode service with read-back verification, i18n'd to Chinese via a hand-built `.lmo` catalog |
| Internal 480×854 MIPI display | ✅ self-drawn status page (Wi-Fi QR, addresses, live counters), power-key backlight, double-buffered; touch deliberately off |
| SMS receive + forward, web dialer | ✅ real messages from the pool; call **audio** is unsolved and suspended (documented, evidence in `docs/changxing60/telephony.md`) |
| Bluetooth, Mali-G57 GPU (headless OpenCL via vendor chroot), zram, thermal zones | ✅ |
| Battery life on its own power | ✅ ~215 mA average over 6 h 53 m on battery; charge-current fixes pinned per boot |
| Self-healing WAN | ⚠ the modem stack wedges probabilistically (`docs/changxing60/sipa-wedge.md`); watchers detect and recover, worst case reboots itself — a wedge, not a mystery, is now on the books |

State of everything, including known issues graded by "can this affect the
network path?", is frozen and recorded in
[`docs/changxing60/state-2026-10-17.md`](docs/changxing60/state-2026-10-17.md).

## Repository layout

| Path | Contents |
|---|---|
| [`docs/changxing60/README.md`](docs/changxing60/README.md) | **Doc index** — 31 dated documents plus the index itself: network port, drivers, reboot-slot logic, IPv6, display, SMS/voice, SIPA wedge, power, conflicts, frozen-state, defect ledger |
| `docs/changxing60/` | The documents themselves (Chinese) |
| `rescue/dumps/` | Sanitized incident evidence: two raw `pstore` crash archives, the frozen device-state snapshot (per-file md5s — the rollback recipe was rehearsed 102/102 OK) |
| `rescue/tools/` | The 32-byte `bootloader_control` generator, GPT prep tool, early trial-net watchers |

Not included in this snapshot, by design: the Android-side Magisk-module notes,
an unrelated reversing subproject, and any vendor binary blobs — those were part
of the private working tree, not of the OpenWrt port.

## Credentials policy

No real credentials are present in this repository or its history: root/LuCI
password, hotspot PSK, IMEI, serials, machine codes and the factory Wi-Fi/Bluetooth MACs are kept outside git
(host tools read `$CHANGXING60_PASSWORD` / `$CHANGXING60_PASSWORD_FILE`). The
shipped image's root account has an **empty password** — that is the stock
behaviour, not an oversight: set your own password and your own PSK before
connecting it to anything.

## Caveats if you pick this up

* Single device, single sample: DTB offsets, partition sizes and vendor ioctl
  shapes are facts about *this* board revision.
* Host-side examples assume WSL with Windows-side adb (`adb exec-out` is banned
  — its CRLF pass corrupted binary pulls twice; see `rescue/dumps/*/SHA256SUMS`
  era notes). Adapt to your environment.
* The 6.18 LTS kernel line is an open experiment; production is 5.4.254.
* Call audio is suspended pending vendor DSP answers — see
  `docs/changxing60/telephony.md` §10 for exactly what was ruled out and why.

## References

* [**dikeckaan/mu300-linux**](https://github.com/dikeckaan/mu300-linux) — the
  F50/MU300 port this project started from as a **reference**; part of its commit
  history rides in the port repo's base, all changxing60 work is authored here.
* The **e5 / UMS9621** port projects — sister-device reference for modem
  handling, CP recovery and repo layout (`docs/changxing60/e5-linux.md` is a
  line-by-line comparison, including where the two projects are wrong in
  different ways).
* ZTE / Unisoc **GPL releases** — the 5.4.251 vendor kernel sources and stock
  configs (`rescue/dumps/7552n-stock.config`) this port builds on.

MIT licensed (see `LICENSE`). Timestamps in the docs are real; the device's
clock runs at UTC+3, five hours behind the host, which matters when
cross-referencing logs.
