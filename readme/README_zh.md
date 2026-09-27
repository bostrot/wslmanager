<h1 align="center">欢迎使用 WSL Manager 👋</h1>

![GitHub Release Date](https://img.shields.io/github/release-date/bostrot/wslmanager?style=for-the-badge)
![GitHub Workflow](https://img.shields.io/github/actions/workflow/status/bostrot/wslmanager/releaser.yml?branch=main&label=nightly&style=for-the-badge)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/bostrot/wslmanager?style=for-the-badge)
[![Documentation](https://img.shields.io/badge/DOCUMENTATION-WIKI-green?style=for-the-badge)](https://github.com/bostrot/wslmanager/wiki)
[![GitLab stars](https://img.shields.io/gitlab/stars/bostrot/wsl2-distro-manager?gitlab_url=https%3A%2F%2Fgitlab.com&label=GitLab&style=for-the-badge)](https://gitlab.com/bostrot/wsl2-distro-manager)
[![Discord](https://img.shields.io/discord/1100070299308937287?style=for-the-badge)](https://discord.gg/fY5uE5WRTP)


<p align='center'>
    <a href='../README.md'>English</a> | 简体中文 | <a href='./README_zh_tw.md'>繁體中文</a> | <a href='./README_de.md'>Deutsch</a> | <a href='./README_es.md'>Español</a> | <a href='./README_ja.md'>日本語</a> | <a href='./README_hu.md'>Magyar</a> | <a href='./README_pt.md'>Português</a> | <a href='./README_tr.md'>Türkçe</a>
</p>

![Windows 上的 WSL Distro Manager，深色主题](./images/home-dark.png)

<p align='center'>
    <sub>图为 <b>Windows</b> 版 &middot; 同一个应用在 <b>macOS</b> 上运行原生虚拟机 &mdash; 展开下方的 <b>在 macOS 上的样子</b></sub>
</p>

<details>
<summary>浅色主题预览（Windows）</summary>

![Windows 上的 WSL Distro Manager，浅色主题](./images/home-light.png)

</details>

<details>
<summary><b>🍎 在 macOS 上的样子</b> &mdash; 通过 Apple 的 Virtualization 框架运行原生 Linux 与 macOS 虚拟机 <i>(beta)</i></summary>

![macOS 上的 WSL Manager，深色主题](./images/home-macos-dark.png)

![macOS 上的 WSL Manager，浅色主题，并打开了 AI 助手](./images/home-macos-light.png)

</details>

> **WSL Distro Manager** 是一款免费开源的图形界面工具，用于管理适用于 Linux 的
> Windows 子系统 —— 在 macOS 上则用于管理原生 Linux 虚拟机。安装、复制、重命名、
> 迁移、备份和删除 WSL 发行版，无需记住任何一个 `wsl.exe` 参数 —— 此外还有模板、
> 保存的命令片段、磁盘挂载、`.wslconfig` 编辑、通过 SSH 管理远程 WSL，以及一个可
> 让 AI 代理驱动你的 WSL 环境的 MCP 服务器。在 Mac 上，同一个应用会改为通过
> Apple 的 Virtualization 框架管理虚拟机。

## 🚀 功能

**管理发行版**
- [x] 从内置目录安装，或使用你自己的 rootfs
- [x] 复制、重命名、迁移到其他驱动器、备份和删除实例
- [x] 把所有实例备份到一个文件夹（附带内容清单），并在另一台电脑上还原
- [x] 压缩虚拟磁盘，回收 WSL 从不主动释放的空间
- [x] 实时查看某个实例正在占用的资源 —— 处理器、内存和交换空间，并附带动态图表
- [x] 支持 Ubuntu、Debian、Alpine、Kali Linux、openSUSE、SLES 以及 WSL 接受的其他系统

**更快让实例跑起来**
- [x] 把任意 Docker 镜像当作发行版使用 —— 无需安装 Docker 本身
- [x] 把配置好的发行版打包成可移植的 `.wsl` 文件，在任何机器上安装（模板已被其取代，不再推荐）
- [x] Turnkey Linux 及其他 LXC 容器（实验性）
- [x] 命令片段：把安装配置命令保存在应用里，在任意实例上运行
- [x] 让应用指向你自己的 rootfs 镜像仓库
- [x] 浏览发行版中的文件，把选中的复制到另一个实例 — 无需共享、无需挂载、无需资源管理器

<!-- Unreleased. Containers, Kubernetes and Cloud are built but ship only in
     debug runs (LicenseManager.unreleasedFeaturesVisible, the gate Pro rides
     in a debug build); a release has none of them, so the README must not
     promise them. Lift the comment together with the gate.

**Docker 与 Podman 容器**
- [x] 在实例旁边查看机器上的每一个容器 —— 两种引擎同时呈现
- [x] 无需离开应用即可启动、停止、重启、删除容器并跟踪其日志
- [x] 仅是前端：它驱动你已经装好的 `docker`/`podman`，不安装任何东西
- [x] AI 聊天和 MCP 服务器获得同一套容器工具

**Kubernetes 集群**
- [x] kubeconfig 中的每个集群，一次专注一个命名空间 —— 为十个集群、上百个应用而设计
- [x] Deployment、StatefulSet 与 DaemonSet 的健康状况一目了然，可按名称、命名空间或镜像筛选
- [x] 打开一个工作负载即可查看其 Pod、跟踪日志、重启某个 Pod、触发滚动重启、伸缩，或阅读完整详情
- [x] 仅是前端：它驱动你已经装好的 `kubectl`，从不改写 kubeconfig，也不切换上下文
- [x] AI 聊天和 MCP 服务器同样能读取你的集群 —— 工作负载、Pod、事件、资源用量以及可搜索的 Pod 日志 —— 而且只能读取：其中没有任何工具可以重启、伸缩或删除

**部署到云端** *(beta)*
- [x] 一步把整个实例推送到一台全新的 Hetzner Cloud 服务器 —— 根文件系统会被导出、上传并在那里以容器方式启动
- [x] 服务器由应用替你创建：规格、位置和基础镜像，并由 cloud-init 安装 Docker、把你自己的 SSH 密钥授权给 `root`
- [x] 在 macOS 上同样可用：Linux 虚拟机的根文件系统是从运行中的客户机里读取的，因为它的磁盘映像是一台可引导的机器，而不是容器引擎能读懂的东西
- [x] 随时把它作为新的本地实例拉回来，同时让服务器继续运行 —— 在 macOS 上会还原到部署来源虚拟机的副本中，该虚拟机必须仍然存在且已停止，因为光有根文件系统没有内核可供引导
- [x] 查看每台服务器每月的费用，开机、关机，并在同一个列表里删除它们
-->

**无需手动编辑文件即可配置**
- [x] 逐个发行版设置 systemd、automount、默认用户、启动命令和启动路径
- [x] 内存、处理器、交换空间、网络模式、DNS 以及 `.wslconfig` 的其余设置
- [x] 把物理磁盘或 VHD 挂载进 WSL，并可控制分区与文件系统
- [x] 将主机文件夹以你选择的挂载点共享到发行版或虚拟机中，可设为只读 — AI Workspace 同样适用

**按你原有的习惯工作**
- [x] 直接在发行版内打开 Windows Terminal、VS Code 或资源管理器
- [x] 每个实例都出现在 Windows 终端菜单中，应用运行期间保持最新——以独立的片段文件添加，你的终端设置不会被改动
- [x] 通过 SSH 管理*另一台* Windows 机器上的 WSL
- [x] 在局域网中的两台机器之间同步发行版
- [x] 用名称访问实例：主机名会写入 hosts 文件，重启后 `ssh ubuntu.wsl` 依然可用
- [x] 自动保持最新：网站版和 GitHub 版会自行下载并安装新版本（商店安装的版本由商店更新）
- [x] 深色与浅色主题，提供九种语言

**在 macOS 上：原生虚拟机** *(beta)*
- [x] 同一个应用改用 Apple 的 Virtualization 框架管理虚拟机，而不是 WSL
- [x] 从安装 ISO、云镜像或导出的模板创建 Linux 虚拟机
- [x] 从恢复镜像创建 macOS 客户机虚拟机（Apple Silicon）
- [x] 像管理发行版一样启动、停止、克隆、导出/导入虚拟机并保存为模板
- [x] 通过自动配置的 SSH（cloud-init）在虚拟机内执行命令，可来自图形界面、AI 聊天或 MCP 客户端
- [x] 在列表行里为任意虚拟机打开终端：Linux 与 macOS 客户机都走 SSH 会话，Linux 上无法连接时才退回串行控制台
- [x] 你自己的 `~/.ssh` 密钥会被授权到每台 Linux 虚拟机（如果没有则替你创建），所以直接 `ssh user@vm-ip` 也能用
- [x] 每台虚拟机都有一个登录密码，可在其列表行中读取，用于在虚拟机自身的界面上登录
- [x] 可在同一行设置所有 SSH 方式登录时使用的账户 —— macOS 客户机的用户名在设置助理中输入，应用无从获知
- [x] 使用 `scripts/build_macos.sh` 构建 —— 会打包签名后的 `vmctl` 助手

**Pro** *（一次性购买：Windows 上通过 Microsoft Store，macOS 及非商店安装则从 [wslmanager.com/buy](https://wslmanager.com/buy/) 获取许可证密钥 —— 绝不是订阅制）*
- [x] **AI Workspace** —— 在专用且隔离的 WSL 发行版中运行 Hermes Agent、OpenClaw、Open WebUI 和 OpenCode
- [x] **所有 AI 工具共用一套模型与端点** —— 设置中 AI 助手的 API 端点、密钥和模型同样用于 OpenCode、OpenClaw 和 Hermes；只需设置一次，之后安装的工具也会自动获得
- [x] **带工具的 AI 助手** —— 内置聊天能够真正*操作*你的 WSL：它会列出并检查发行版、执行命令、修改配置、创建片段、挂载磁盘并打包发行版，用的正是 MCP 服务器暴露的同一套工具
- [x] **每次更改实例的 AI 运行都会保存为片段** —— 记录执行过的命令和各工具的反馈，并从聊天中链接过去，方便你复查、在新实例上重新运行或分享
- [x] **沙箱 AI** —— 启动一个用完即弃的 Ubuntu 发行版，并让 AI 聊天*只能*访问该沙箱内部
- [x] **任务队列** —— 把清单交给助手，让它逐项完成并依次打勾
- [x] **MCP 服务器** —— 把 WSL 暴露给 Claude Desktop、Claude Code、opencode 及其他 MCP 客户端
- [x] **网页面板** —— 从手机或另一台电脑管理一切：扫描二维码，在浏览器中获得整个应用，并可选择通过 Cloudflare 隧道发布到网络之外

> AI 功能使用**你自己**提供的凭据 —— 你自己的 OpenAI 兼容 API 密钥。本应用不托管
> 也不附带任何 AI 服务，没有额度限制，也没有任何请求经过他人的服务器。Pro 解锁的
> 是应用中的功能，而不是购买 AI 额度。参见
> [Free vs Pro](https://github.com/bostrot/wslmanager/wiki/Pro-Version)。

> **为什么会有付费版？** 自 2021 年起，WSL Manager 一直是一个人利用业余时间做的
> 项目，上面的每一项功能 —— 包括免费的那些 —— 都是在夜晚和周末写出来的。管理发行版
> 和虚拟机是免费的，并且会一直免费，整个应用也会保持开源。Pro 是叠加在上面的 AI
> 层，它带来的收入使维护和新功能成为有计划的常规工作，而不是只能用剩余时间去做。
> 一次购买，永久拥有，你就是在直接资助下一个版本。

> 🎁 **上线优惠 —— 前 100 位用户免费获得 Pro。** 打开已自动填入 `START100` 优惠码
> 的结账页面，下一页就会显示你的许可证密钥：
> [**Windows**](https://buy.stripe.com/5kQeVd6ECgur3wJ2TO1Fe03?prefilled_promo_code=START100) ·
> [**macOS**](https://buy.stripe.com/dRm00jbYWfqnaZb1PK1Fe02?prefilled_promo_code=START100)。
> 每人限一份许可证；100 份领完后优惠码即失效。

## 🤖 AI 助手与 MCP *(Pro)*

本节的全部内容都属于 **Pro**；免费版不包含其中任何一项。

AI 助手是一个**代理**，而不只是聊天框：它拿到的正是 MCP 服务器暴露的那套工具，
所以当你问“我有哪些发行版？”或说“安装 Ubuntu 并设置我的默认用户”时，它会对你的
WSL 调用真实工具，而不是靠猜。工具调用会在它工作时内联显示出来。

**设置服务提供方**：在**设置 → Bring Your Own AI Key**中，任何 OpenAI 兼容端点都
可以（OpenAI、Azure、LiteLLM 代理、Ollama、LM Studio……）。填入基础 URL、密钥和
模型。**加载模型列表**按钮会用服务提供方的 `/models` 填充自动补全，**测试连接**
则在你打开聊天之前先验证凭据可用。

**一样都不想要？** **设置 → Bring Your Own AI Key → AI 功能** 可以关闭助手、错误诊断和 AI Workspace —— 不会显示任何与 AI 相关的内容，也不会为你准备工作区环境。在你作答之前它一直是关闭的：WSL Manager 只会在安装或更新后的首次启动时询问一次，在那之前不会运行任何与 AI 相关的内容。

**沙箱**（AI Workspace → *添加沙箱发行版*）会从任意目录镜像（默认是最新的 Ubuntu）
创建一个用完即弃的实例 —— 在 Windows 上是 WSL 发行版，在 macOS 上是由云镜像生成的
Linux 虚拟机，二者都会替你创建并启动。它的聊天只会拿到 `sandbox_*` 工具，且这些
工具被锁定在那一个实例上 —— 模型可以在沙箱*内部*做任何事，却永远看不到你的宿主机
或其他实例。一个诚实的提醒：沙箱本身拥有正常的对外网络访问，和任何发行版或虚拟机
一样。沙箱聊天与助手共用同一个停靠面板（含任务队列），其对话记录会被保留，聊天标题
栏中的历史按钮可在助手和任意沙箱会话之间切换。

**任务队列** —— 打开聊天顶部的*任务*区域，添加条目，然后按 ▶。助手会用它的工具逐项
完成，并在完成时打勾；运行期间你仍可继续添加任务。

### 连接外部 AI 客户端（MCP）

打开**设置 → MCP 服务器**（Pro）。它会在 `http://127.0.0.1:59133/mcp` 上提供 MCP
协议，仅监听回环地址，并由同一面板中显示的 bearer 令牌保护。这些工具覆盖完整生命
周期 —— 创建、导入、配置、运行、打包，以及（在带确认标志时）注销发行版，还有命令
片段、磁盘挂载和持久终端会话。

**Claude Desktop** —— 在 MCP 面板中点击**连接 Claude Desktop**。它会替你把下面的
配置写入 `claude_desktop_config.json`（需要 Node.js）；之后重启 Claude Desktop。
若要手动配置，或用于任何其他 stdio MCP 客户端，请用
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) 桥接该 HTTP 端点：

```jsonc
// claude_desktop_config.json  (%APPDATA%\Claude\)
{
  "mcpServers": {
    "wsl-manager": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "http://127.0.0.1:59133/mcp",
        "--header", "Authorization:${AUTH_HEADER}"
      ],
      "env": { "AUTH_HEADER": "Bearer <TOKEN FROM THE MCP PANEL>" }
    }
  }
}
```

**Claude Code** —— 同样的桥接，一条命令：

```bash
claude mcp add wsl-manager -- npx -y mcp-remote http://127.0.0.1:59133/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

**opencode** —— 在你的 `opencode.json`（或 `~/.config/opencode/opencode.json`）中的 `mcp` 下添加：

```jsonc
{
  "mcp": {
    "wsl-manager": {
      "type": "local",
      "command": ["npx", "-y", "mcp-remote", "http://127.0.0.1:59133/mcp",
                  "--header", "Authorization: Bearer <TOKEN>"]
    }
  }
}
```

任何支持流式 HTTP 的 MCP 客户端也可以直接指向该端点，只需带上
`Authorization: Bearer <TOKEN>` 请求头，无需 `mcp-remote`。若要从另一台机器访问，
请在同一面板中启用内置的 **Cloudflare 隧道**开关，并使用它输出的公网 URL。

## 📱 网页面板 *(Pro)*

打开**设置 → 网页面板**（Pro），应用便会在 `59134` 端口上为你网络中的每台设备提供一个
浏览器面板 —— Windows 和 macOS 皆然。用手机扫描面板显示的二维码（或复制链接），你就能
在浏览器里得到整个应用：启动、停止、复制和删除实例，执行命令，打开持久终端会话，运行
保存的命令片段，并通过自动生成的表单使用其余所有工具（导入、导出、打包、`.wslconfig`、
磁盘、创建虚拟机）。这与 AI 助手和 MCP 服务器使用的是同一套工具。

访问由链接中的令牌保护（`?token=…`），因此扫一个二维码就是设备所需的全部 —— 而在面板中
重新生成令牌会吊销此前发出的每一个链接。该面板刻意监听所有网络接口；当你不在家而需要
临时的公网 HTTPS 链接时，可在同一面板中切换**通过 Cloudflare 隧道发布**（二维码会随之
切换）。一旦发布，令牌就是保护这个可执行命令的界面的唯一屏障，所以请谨慎分享该链接。

## 📦 安装

<details>
<summary>Microsoft Store</summary>

本应用已上架 [Microsoft Store](https://apps.microsoft.com/store/detail/wsl-manager/9NWS9K95NMJB?hl=en-us&gl=US)。
</details>

<details>
<summary>macOS 通过 Homebrew 安装</summary>

```sh
brew install --cask wsl-manager
```

Apple Silicon，macOS 11 或更高版本。该 cask 已随 Homebrew 本体提供，无需添加 tap；`brew upgrade --cask wsl-manager` 会获取新版本。
</details>

<details>
<summary>直接下载</summary>

你可以从 [Releases](https://github.com/bostrot/wslmanager/releases) 页面直接下载本应用。Windows 提供安装版 `.exe`、`.msix` 和便携版 `.zip`；macOS 提供 `.dmg`。
</details>

<details>
<summary>通过 Winget 安装</summary>

```sh
winget install Bostrot.WSLManager
```

</details>

<details>
<summary>通过 Scoop 安装</summary>

```sh
scoop install extras/wsl2-distro-manager
```

</details>

<details>
<summary>通过 Chocolatey 安装</summary>

该软件包由社区维护（[@mikeee](https://github.com/mikeee/ChocoPackages)），并非官方包。

```sh
choco install wsl2-distro-manager
```

</details>

<details>
<summary>安装每夜构建版</summary>

最新的每夜构建版可在 “releaser” 工作流的构建产物中找到，或通过[此链接](https://nightly.link/bostrot/wslmanager/workflows/releaser/main/wsl2-distro-manager-nightly-archive.zip)获取。

</details>

## ⚙️ 构建

请确保已安装 [flutter](https://flutter.dev/desktop)。

### Windows

```powershell
flutter config --enable-windows-desktop
flutter upgrade

flutter build windows # build it
flutter run -d windows # run it
```

### macOS

虚拟机由 `vmctl` 创建 —— 那是一个驱动 Virtualization.framework 的小型 Swift 助手，
而不是 Flutter 应用本身。该框架只响应带有 `com.apple.security.virtualization` 授权
的进程，而 `swift build` 不会添加这项授权，因此**必须先构建并签名该助手，应用才能
启动虚拟机**：

```bash
flutter config --enable-macos-desktop

# Build + sign vmctl and install it for dev runs. Re-run after any change
# under macos/vmctl/ — `flutter run` never rebuilds the helper.
VMCTL_ONLY=1 scripts/build_macos.sh

flutter run -d macos
```

跳过这一步，应用照样能启动，但启动虚拟机时会失败并报出：

```
VM failed to start: Error Domain=VZErrorDomain Code=2 "The process doesn't
have the "com.apple.security.virtualization" entitlement."
```

缺少授权的是*助手*，而不是应用 —— `Runner` 自身的授权本来就是对的。签名后的助手会被
安装到 `~/Library/Application Support/WSLManager/bin/vmctl`，调试运行正是在那里查找；
没有它时，调试运行会回退到 `macos/vmctl/.build/` 下未签名的 `swift build` 产物，也就
出现了上面的错误。

不带 `VMCTL_ONLY` 运行 `scripts/build_macos.sh` 会做同样的签名，然后构建发布版应用，
并把签名后的助手打包进 bundle 的 `Contents/Resources/`。构建应用本身需要完整的 Xcode。

## 作者

👤 **Eric Trenkel**

- 网站：[erictrenkel.com](https://erictrenkel.com)
- GitHub：[@bostrot](https://github.com/bostrot)
- LinkedIn：[@erictrenkel](https://linkedin.com/in/erictrenkel)

👥 **贡献者**

[![Contributors](https://contrib.rocks/image?repo=bostrot/wslmanager)](https://github.com/bostrot/wslmanager/graphs/contributors)

## 🤝 参与贡献

欢迎贡献代码、提交问题和功能请求！\
欢迎查看 [issues 页面](https://github.com/bostrot/wslmanager/issues)。
你也可以看看[贡献指南](https://github.com/bostrot/wslmanager/blob/main/CONTRIBUTING.md)。

## 表达支持

如果这个项目帮到了你，请给一个 ⭐️！

## 📝 许可证

版权所有 © 2026 [Eric Trenkel](https://github.com/bostrot)。\
本项目基于 [GPL-3.0](https://github.com/bostrot/wslmanager/blob/main/LICENSE) 许可证。

---

_没找到你想要的内容？看看 [Wiki](https://github.com/bostrot/wslmanager/wiki)_
