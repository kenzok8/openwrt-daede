<h1 align="center">openwrt-daede</h1>

<p align="center">All-in-one package for OpenWrt: the <b>dae</b> core + <b>daed</b> companion + <b>luci-app-daede</b> admin interface.</p>

<p align="center">English · <a href="README.md">中文</a></p>

<div align="center">
  <a href="https://github.com/kenzok8/openwrt-daede/releases"><img alt="Release" src="https://img.shields.io/github/v/release/kenzok8/openwrt-daede?style=flat-square&label=release"></a>
  <a href="https://github.com/kenzok8/openwrt-daede/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/kenzok8/openwrt-daede/total?style=flat-square&label=downloads"></a>
  <a href="https://github.com/kenzok8/openwrt-daede/commits/main"><img alt="Last commit" src="https://img.shields.io/github/last-commit/kenzok8/openwrt-daede/main?style=flat-square"></a>
  <a href="https://github.com/kenzok8/openwrt-daede/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/kenzok8/openwrt-daede?style=flat-square"></a>
  <a href="https://github.com/kenzok8/openwrt-daede/issues?q=is%3Aissue+is%3Aclosed"><img alt="Closed issues" src="https://img.shields.io/github/issues-closed/kenzok8/openwrt-daede?style=flat-square"></a>
  <a href="https://github.com/kenzok8/openwrt-daede/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/kenzok8/openwrt-daede?style=flat-square"></a>
</div>

<p align="center">
  <img src="https://raw.githubusercontent.com/kenzok8/kenzok8/main/screenshot/daede/dae-logo.png" height="88" alt="dae">
  &nbsp;&nbsp;&nbsp;
  <img src="https://raw.githubusercontent.com/daeuniverse/daed/main/apps/web/public/logo-rounded.png" height="88" alt="daed">
</p>

## What is this

| Component | Description |
| :--- | :--- |
| **dae** | A high-performance transparent proxy core based on eBPF. Traffic is split in kernel space, so direct traffic costs almost nothing — a good fit as the main proxy on a software router |
| **daed** | The "web dashboard" distribution of dae (daed app + dae-wing + dae core + embedded frontend), graphical management out of the box |
| **luci-app-daede** | A unified admin interface: **one UCI config drives both dae and daed**, so switching cores needs no reinstall |

## Supported targets

| Architecture | SDK | Package format |
| :--- | :--- | :--- |
| `x86_64` · `i386_pentium4` | 24.10 / 25.12 | ipk / apk |
| `aarch64_generic` · `aarch64_cortex-a53` · `aarch64_cortex-a72` | 24.10 / 25.12 | ipk / apk |
| `arm_cortex-a7_neon-vfpv4` · `arm_cortex-a9` · `arm_cortex-a9_neon` | 24.10 / 25.12 | ipk / apk |

8 architectures × 2 SDKs = 16 build targets (see the `release.yml` matrix). armv7 builds with the `vmlinux-arm.h` patch ported from [sbwml/openwrt_helloworld](https://github.com/sbwml/openwrt_helloworld), which fixes trace eBPF compilation.

- System requirements: OpenWrt 24.10 / 25.12 (25.12 recommended); the kernel must support XDP sockets (the dae / daed Makefiles depend on `KERNEL_XDP_SOCKETS`).
- Need firmware with BTF built in: build it online with [`kenzok8/imagebuilder`](https://github.com/kenzok8/imagebuilder), whose kernels already enable BTF.

## Screenshots

<details open>
<summary><b>Desktop Screenshots</b></summary>
<br>
<table>
<tr>
<td align="center"><b>dae Config</b><br><img width="400" src="https://raw.githubusercontent.com/kenzok8/kenzok8/main/screenshot/daede/dae-config.png"></td>
<td align="center"><b>daed Config</b><br><img width="400" src="https://raw.githubusercontent.com/kenzok8/kenzok8/main/screenshot/daede/daed-config.png"></td>
</tr>
<tr>
<td align="center"><b>Updates</b><br><img width="400" src="https://raw.githubusercontent.com/kenzok8/kenzok8/main/screenshot/daede/daede-updates.png"></td>
<td align="center"><b>Log</b><br><img width="400" src="https://raw.githubusercontent.com/kenzok8/kenzok8/main/screenshot/daede/daede-log.png"></td>
</tr>
</table>
</details>

<details>
<summary><b>Mobile Screenshots</b></summary>
<br>
<table>
<tr>
<td align="center"><b>Config</b><br><img width="200" src="https://raw.githubusercontent.com/kenzok8/kenzok8/main/screenshot/daede/mobile-daede-config.png"></td>
<td align="center"><b>Updates</b><br><img width="200" src="https://raw.githubusercontent.com/kenzok8/kenzok8/main/screenshot/daede/mobile-daede-updates.png"></td>
<td align="center"><b>Log</b><br><img width="200" src="https://raw.githubusercontent.com/kenzok8/kenzok8/main/screenshot/daede/mobile-daede-log.png"></td>
</tr>
</table>
</details>

## Install

### One-click install

This script downloads and installs the packages directly; it does not write a software feed into the system. To keep upgrading online from LuCI's Updates page, also configure the feed as described below.
It installs `dae`, `daed` and LuCI by default, and downloads the GeoIP / GeoSite dependencies; set `DAEDE_CORE=daed` if you only need `daed`.

```bash
# Recommended in mainland China: jsDelivr mirror, more stable than ghfast-style accelerators
wget -O - https://cdn.jsdelivr.net/gh/kenzok8/openwrt-daede@main/scripts/install.sh | ash
```

```bash
# Direct GitHub: use when the mirror has not synced the latest script yet
wget -O - https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh | ash
```

A device that previously installed only `daed` gets `dae` added by re-running the default command; no feed setup is needed first.

To install only the `daed` core:

```bash
wget -O - https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh | DAEDE_CORE=daed ash
```

> jsDelivr caches `@main` (up to about 12 hours), so a freshly changed script may take effect late.
> Package downloads go through `GITHUB_PROXY_PREFIX` (default `https://ghfast.top/`) and fall back to direct GitHub on failure;
> to use another accelerator: `GITHUB_PROXY_PREFIX=https://your-mirror/ wget -O - ... | ash`.

### Uninstall

```bash
wget -O - https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/uninstall.sh | ash
```

## Upgrade

Two ways — pick one.

**① Re-run the install script** (no feed setup needed, most reliable)

```bash
wget -O - https://cdn.jsdelivr.net/gh/kenzok8/openwrt-daede@main/scripts/install.sh | ash
```

**② Add the software feed**, then upgrade from LuCI's Updates page. LuCI can only query and upgrade packages once the project feed is installed and configured. Run this on your OpenWrt router:

```bash
wget -qO- https://down.dllkids.xyz/openwrt-feed/openwrt-feed-setup.sh | sh
```

The script automatically:

- ✅ Detects the SDK version (24.10 / 25.12) and CPU architecture
- ✅ Checks that the feed exists for that architecture (covers all three index types: `Packages.gz` / `APKINDEX.tar.gz` / `packages.adb`), falling back to `all` when missing
- ✅ Downloads the matching public key: opkg → `opkg-key add`; apk → into `/etc/apk/keys/`
- ✅ Writes / updates the feed config (`customfeeds.conf` or `/etc/apk/repositories`) without duplicating entries
- ✅ Runs `opkg update` / `apk update`; the script only configures the feed, it does not install dae/daed

The public feed setup script retries with `--allow-untrusted` when `apk update` fails. If you see that warning, fix the feed or public key first, then upgrade online from LuCI; do not treat a relaxed refresh as a passed signature check.

## Usage

1. After installing, go to LuCI → Services → daede
2. Pick a backend (dae or daed) — both backends share the same eBPF mount points and **cannot run at the same time**; LuCI stops the other one automatically when you switch
3. Import your config and start the service

📖 **Docs site**: [kenzok8.github.io/openwrt-daede](https://kenzok8.github.io/openwrt-daede/) — install, subscriptions, groups, routing, DNS and FAQ.
📖 **Beginner tutorial**: [dae backend guide](https://github.com/kenzok8/openwrt-daede/wiki) — how to fill in subscriptions, nodes, groups, routing and DNS, plus common questions in one article.

## Dependencies

| Package | Description |
| :--- | :--- |
| `ca-bundle` | CA certificate bundle (subscription fetches, dashboard HTTPS checks) |
| `curl` | Download tool (Geo data updates, proxy connectivity checks) |
| `kmod-sched-core` / `kmod-sched-bpf` | eBPF traffic scheduling (kernel-space split mount points) |
| `kmod-veth` | Virtual Ethernet devices (the dae0 dataplane) |
| `v2ray-geoip` / `v2ray-geosite` | GeoIP / GeoSite routing data; the install script downloads them from the feed |
| `vmlinux-btf` | Optional: supplies BTF when the kernel has none built in (Makefile option, defaults to kernel BTF) |
| `luci-base` | LuCI runtime dependency |

See `dae/Makefile`, `daed/Makefile` and `luci-app-daede/Makefile` for the full dependency lists. `luci-app-daede` pulls the `daed` backend by default (the backend choice in its Makefile; `dae` can be selected instead).

### Kernel BTF (required for CO-RE eBPF)

dae / daed use CO-RE eBPF and need kernel BTF at runtime (`/sys/kernel/btf/vmlinux`). Kernels built with `CONFIG_DEBUG_INFO_BTF` ship it (ImmortalWrt 25.12 and the like); official OpenWrt, online ImageBuilder and similar firmware often **do not**, and daed then fails to start.

Remedies:

- Install a matching **[kenzok8/vmlinux-btf](https://github.com/kenzok8/vmlinux-btf)** package to supply BTF (the one-click install script also downloads the matching-architecture package from the feed and installs it alongside; the script takes the first entry in the feed listing and does not match on `uname -r` exactly)
- Or flash firmware with a BTF-enabled kernel: **[kenzok8/imagebuilder](https://github.com/kenzok8/imagebuilder)** (generated online, kernel already has BTF)

<details>
<summary><b>How the core is built: performance, reproducibility, wide architecture coverage</b></summary>

Not just repackaged upstream binaries, but a **reproducible, performance-tuned, self-hosted** source build chain:

1. **Performance stack** (the core difference from stock dae)
   - **dae core**: tracks [daeuniverse/dae](https://github.com/daeuniverse/dae) official `main`; at assemble time the [olicesx](https://github.com/olicesx) performance fork is the baseline and official main is merged on top (eBPF dataplane optimizations: connection-state merging, egress redirect, DNS/UDP path optimizations, etc.). The core always stays in sync with upstream while keeping the performance fork
   - **QUIC**: the quic-go baseline already contains all historical performance patches (B-tree node pooling, GSO send fixes, etc., merged into the baseline on 2026-07-31); `ci/patches/quic-go/` is currently empty and kept for future backports. The baseline commit matches what outbound's go.mod requires (`QUICGO_BASE_COMMIT` = `QUICGO_PERF_TIP`)
   - **Outbound**: `outbound` still uses the olicesx optimization branch (anytls/sticky-ip and more). The fork is large, so it stays on upstream for now, mirrored to kenzok8/outbound against deletion; plus 2 self-owned patches (`ci/patches/outbound/`: REALITY client version bytes, anytls insecure aliases)
   - **PGO** (Profile-Guided Optimization): a vendored `ci/default.pgo` profile, with `-pgo=auto` letting the compiler optimize for real hot spots
   - **Go 1.27** + `GOEXPERIMENT=newinliner,simd` (new inliner + SIMD), static linking, `-trimpath`

2. **Reproducible builds**
   - Every upstream commit is pinned in `ci/pins.env` (the single source of truth)
   - The assemble workflows freeze the pinned-commit sources into **self-hosted tarballs** (published in this repo as `dae-src` / `daed-src`) and write `PKG_HASH`
   - The SDK only go-compiles that frozen source — old commits stay reproducible forever, unaffected by upstream changes

3. **Advantages over other third-party dae/daed builds**
   - **Faster**: performance fork + PGO + the new Go optimizer, not a straight daeuniverse repack
   - **More stable**: self-hosted frozen sources + `PKG_HASH`; upstream force-pushes or repo deletions never break historical builds
   - **More complete**: one `luci-app-daede` manages both dae and daed, with **hot core switching and no reinstall**; architecture coverage reaches armv7
   - **Traceable**: every dependency commit is pinned in one place (`ci/pins.env`); assembly and release are fully automated and leave a trail

### External dependencies and closure status

| Dependency | Source | Status |
|------|------|------|
| **PGO profile** | Self-sampled | ✅ **Vendored** (`ci/default.pgo`, fully closed) |
| **dae core** | daeuniverse/dae `main` + olicesx performance baseline (merged at assemble time) | ✅ **Tracks upstream + keeps performance**: the core follows upstream while the performance fork is the frozen baseline, no longer affected by olicesx lag |
| **quic-go** | Baseline + self-owned patch directory `ci/patches/quic-go/` (currently empty) | ✅ **Fully closed**: the historical performance patches are merged into the baseline, the directory is kept for future backports; the baseline is mirrored, so an olicesx deletion has no effect |
| **outbound** | [olicesx](https://github.com/olicesx) → mirror [kenzok8](https://github.com/kenzok8) | ⚠️ **Half-closed**: large fork, stays on upstream for now (mirrored against deletion); 2 self-owned patches applied at assemble time |
| **True upstream** | [daeuniverse/dae](https://github.com/daeuniverse/dae) · [daed](https://github.com/daeuniverse/daed) · dae-wing | 🔗 **Actively followed** (the real source — following it is right) |

> Design philosophy: **internalize the volatile, deletable middle layers step by step** — PGO is vendored, quic-go performance is merged into the baseline, and the dae core now tracks official main (olicesx performance as the merged baseline); only outbound still rides upstream because its fork is too large. See `ci/PERF-PATCHES.md` for details.

</details>

<details>
<summary><b>Maintainer release flow</b></summary>

To publish a code fix manually, run "Sync and release dae/daed" in Actions and select the `current` lane, then wait for the candidate checks and the 16-target build to pass. Retest the built packages on a test device, then in "Promote verified daede candidate" enter only the candidate SHA from the run summary. Promotion reuses the verified packages and waits for the public feed aggregation to finish. Running `release.yml` alone only builds candidate packages and never updates the public feed.

Scheduled upstream syncs still check, verify and auto-promote on the `core` / `perf` lanes; `ENABLE_UNATTENDED_RELEASE` controls whether the scheduled run auto-publishes, and does not affect manual `current` candidate builds.

</details>

## Credits

- [dae](https://github.com/daeuniverse/dae) — high-performance transparent proxy
- [daed](https://github.com/daeuniverse/daed) — dashboard-enhanced dae

## License

See the LICENSE file in the repo.
