<h1 align="center">openwrt-daede</h1>

<p align="center">OpenWrt 一体包：<b>dae</b> 内核 + <b>daed</b> 配套 + <b>luci-app-daede</b> 管理界面。</p>

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

## 固件支持

需要用于支持 `dae` / `daed` 的固件，可使用
[`kenzok8/imagebuilder`](https://github.com/kenzok8/imagebuilder) 构建。

## 界面预览

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

## 关于 dae / daed

- **dae** —— 基于 eBPF 的高性能透明代理内核。流量在内核态分流，直连流量几乎零开销，适合做软路由主力代理。
- **daed** —— dae 的「带 Web 面板」发行版（daed app + dae-wing + dae 核心 + 内嵌前端），开箱即用的图形化管理。
- **luci-app-daede** —— 统一管理界面，**同一套 UCI 配置同时适配 dae 和 daed**，内核切换无需重装。

### 我们的内核是怎么构建的

不是简单打包上游二进制，而是一条**可复现、性能优化、自托管**的源码构建链：

1. **性能优化栈**（相比原版 dae 的核心差异）
   - **dae 核心**：追 [daeuniverse/dae](https://github.com/daeuniverse/dae) 官方 `main`，装配时把 [olicesx](https://github.com/olicesx) 的性能 fork 作基线、官方 main merge 在其上（eBPF 数据面优化：连接状态合并、egress 重定向、DNS/UDP 路径优化等）。核心永远跟官方同步，又保住性能 fork
   - **QUIC**：基线 + 我们自持的性能补丁（`ci/patches/quic-go/`，B-tree 节点池优化），复现的 perf tip **
   - **出站**：`outbound` 仍用 olicesx 的优化分支（anytls/sticky-ip 等，分叉较大暂骑上游）
   - **PGO**（Profile-Guided Optimization）：内置 `ci/default.pgo` 采样档，`-pgo=auto` 让编译器按真实热点优化
   - **Go 1.26** + `GOEXPERIMENT=newinliner,simd`（新内联器 + SIMD），静态链接、`-trimpath`

2. **可复现构建**
   - 所有上游 commit 锁定在 `ci/pins.env`（单一事实来源）
   - 装配工作流把固定 commit 的源码冻结成**自托管 tarball**（发布在本仓库 `dae-src` / `daed-src`），并写入 `PKG_HASH`
   - SDK 只 go-compile 这份冻结源 —— 旧 commit 永远能复现，不受上游变动影响

3. **广架构覆盖**
   - x86_64 / i386 / aarch64（a53/a72/generic）/ **armv7（a7/a9）** 出完整内核包
   - armv7 通过移植 [sbwml/openwrt_helloworld](https://github.com/sbwml/openwrt_helloworld) 的 `vmlinux-arm.h` 补丁解决 trace eBPF 编译问题

### 三个外部依赖与闭合状态

| 依赖 | 来源 | 状态 |
|------|------|------|
| **PGO 采样档** | 自采样 | ✅ **已 vendored**（`ci/default.pgo`，完全闭合） |
| **dae 核心** | daeuniverse/dae `main` + olicesx 性能基线（装配时 merge） | ✅ **追官方 + 保性能**：核心跟官方同步，性能 fork 作冻结基线，不再受 olicesx 滞后影响 |
| **quic-go** | 基线 + 自持补丁 `ci/patches/quic-go/` | ✅ **完全闭合 + 与官方同步**：补丁复现的 perf tip 即官方 dae 所 pin，olicesx 删库无影响 |
| **outbound** | [olicesx](https://github.com/olicesx) → 镜像 [kenzok8](https://github.com/kenzok8) | ⚠️ **半闭合**：130 commit 大分叉，暂骑上游（已镜像防删） |
| **真上游** | [daeuniverse/dae](https://github.com/daeuniverse/dae) · [daed](https://github.com/daeuniverse/daed) · dae-wing | 🔗 **主动跟随**（真源头，追它是对的） |

> 设计哲学：**把易变、会删的中间层逐步内化**——PGO 已 vendored、quic-go 性能已转自持补丁、dae 核心改追官方 main（olicesx 性能作基线 merge）；只剩 outbound 因分叉过大暂骑上游。详见 `ci/PERF-PATCHES.md`。

### 相比其他第三方 dae/daed 的优势

- **更快**：性能 fork + PGO + 新 Go 优化器，不是原版 daeuniverse 直接打包
- **更稳**：自托管冻结源 + `PKG_HASH`，上游 force-push / 删库都不影响历史版本构建
- **更全**：一个 `luci-app-daede` 同时管 dae 和 daed，**热切换内核不用重装**；架构覆盖到 armv7
- **可追溯**：所有依赖 commit 在 `ci/pins.env` 一处锁定，装配 / 发布全自动且留痕

### 包含什么

- `dae` —— 性能优化版 dae 内核（eBPF 透明代理）
- `daed` —— daed app + dae-wing + dae 核心 + outbound + quic-go + 内嵌 Web 面板
- `luci-app-daede` —— 双内核统一 LuCI 管理界面

## 安装

### 一键安装

此脚本直接下载安装包，不会把软件源写入系统。若需要在 LuCI「更新」页持续在线升级，还需按下方步骤配置软件源。
默认安装 `dae`、`daed` 和 LuCI，并下载 GeoIP、GeoSite 依赖；仅需 `daed` 时可设置 `DAEDE_CORE=daed`。

```bash
# 大陆推荐：jsDelivr 镜像，比 ghfast 之类的加速站稳定
wget -O - https://cdn.jsdelivr.net/gh/kenzok8/openwrt-daede@main/scripts/install.sh | ash
```

```bash
# 直连 GitHub（镜像还没同步到最新脚本时用）
wget -O - https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh | ash
```

此前只安装 `daed` 的设备，重新运行默认命令即可补装 `dae`，无需先配置软件源。

仅安装 `daed` 内核：

```bash
wget -O - https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/install.sh | DAEDE_CORE=daed ash
```

> jsDelivr 对 `@main` 有缓存（最长约 12 小时），刚改过的脚本可能延迟生效。
> 安装包下载默认走 `GITHUB_PROXY_PREFIX`（默认 `https://ghfast.top/`），失败会自动回落到直连 GitHub；
> 想换加速站可以 `GITHUB_PROXY_PREFIX=https://你的加速站/ wget -O - ... | ash`。

### Release 手动安装

安装并配置项目软件源后，LuCI 才能查询和升级软件包。在 OpenWrt 路由器上执行以下命令：

```bash
wget -qO- https://down.dllkids.xyz/openwrt-feed/openwrt-feed-setup.sh | sh
```

脚本自动完成：

- ✅ 检测 SDK 版本（24.10 / 25.12）与处理器架构
- ✅ 检测该架构 feed 是否存在（覆盖 `Packages.gz` / `APKINDEX.tar.gz` / `packages.adb` 三类索引），缺则回退 `all`
- ✅ 下载对应公钥，opkg → `opkg-key add`；apk → 放入 `/etc/apk/keys/`
- ✅ 写入/更新源配置（`customfeeds.conf` 或 `/etc/apk/repositories`），不会重复堆积
- ✅ 执行 `opkg update` / `apk update`；该脚本只配置软件源，不安装 dae/daed

当前公开的源配置脚本在 `apk update` 失败时会尝试 `--allow-untrusted`。如果出现这条警告，请先修复软件源或公钥，再使用 LuCI 在线升级；不要把放宽校验的刷新结果当成已通过签名验证。

### 维护者发布

手动发布代码修复时，在 Actions 的「Sync and release dae/daed」中选择 `current`，等待候选检查和 16 目标构建成功。用该次构建的包在测试设备上复测后，在「Promote verified daede candidate」中只填写运行摘要里的候选 SHA。晋升会复用已验证的包，并等待公开源聚合完成。`release.yml` 单独运行只构建候选包，不会更新公开源。

定时上游同步仍按 `core` / `perf` 检查、验证和自动晋升；`ENABLE_UNATTENDED_RELEASE` 控制定时自动发布，不影响手动 `current` 候选构建。

### 卸载

```bash
wget -O - https://raw.githubusercontent.com/kenzok8/openwrt-daede/refs/heads/main/scripts/uninstall.sh | ash
```

## 使用

1. 安装后进入 LuCI「服务 → daede」
2. 选择后端（dae 或 daed）
3. 导入配置文件并启动

📖 **新手教程**：[dae 后端使用指南](https://github.com/kenzok8/openwrt-daede/wiki) —— 订阅、节点、分组、路由、DNS 怎么填，常见问题一篇讲清。

## 依赖

| 包名 | 说明 |
|------|------|
| `ca-bundle` | CA 证书包 |
| `kmod-sched-core` | eBPF 调度核心 |
| `kmod-sched-bpf` | eBPF 流量分类 |
| `kmod-veth` | 虚拟以太网设备 |
| `kmod-xdp-sockets-diag` | XDP socket 诊断 |
| `kmod-nft-tproxy` | nftables TPROXY 支持 |

dae / daed 二进制由用户按需安装，luci-app-daede 的 Makefile 会自动拉取对应后端包。

### 内核 BTF（eBPF CO-RE 必需）

dae / daed 用 CO-RE eBPF，运行时需要内核 BTF（`/sys/kernel/btf/vmlinux`）。开了 `CONFIG_DEBUG_INFO_BTF` 的内核自带（ImmortalWrt 25.12 等）；官方 OpenWrt、在线 ImageBuilder 等固件常**未开**，daed 会启动失败。

补救方式：

- 装匹配内核的 **[kenzok8/vmlinux-btf](https://github.com/kenzok8/vmlinux-btf)** 包补上 BTF（一键安装脚本会自动检测并拉取匹配你内核 + 架构的包）
- 或刷带 BTF 内核的固件：**[kenzok8/imagebuilder](https://github.com/kenzok8/imagebuilder)**（在线生成，内核已开 BTF）

## 系统要求

- OpenWrt 24.10+（推荐 25.x）

## 致谢

- [dae](https://github.com/daeuniverse/dae) — 高性能透明代理
- [daed](https://github.com/daeuniverse/daed) — dae 的 Dashboard 增强版

## 许可证

见仓库内 LICENSE 文件。
