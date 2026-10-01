<h1 align="center">歡迎使用 WSL Manager 👋</h1>

![GitHub Release Date](https://img.shields.io/github/release-date/bostrot/wslmanager?style=for-the-badge)
![GitHub Workflow](https://img.shields.io/github/actions/workflow/status/bostrot/wslmanager/releaser.yml?branch=main&label=nightly&style=for-the-badge)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/bostrot/wslmanager?style=for-the-badge)
[![Documentation](https://img.shields.io/badge/DOCUMENTATION-WIKI-green?style=for-the-badge)](https://github.com/bostrot/wslmanager/wiki)
[![GitLab stars](https://img.shields.io/gitlab/stars/bostrot/wsl2-distro-manager?gitlab_url=https%3A%2F%2Fgitlab.com&label=GitLab&style=for-the-badge)](https://gitlab.com/bostrot/wsl2-distro-manager)
[![Discord](https://img.shields.io/discord/1100070299308937287?style=for-the-badge)](https://discord.gg/fY5uE5WRTP)


<p align='center'>
    <a href='../README.md'>English</a> | <a href='./README_zh.md'>简体中文</a> | 繁體中文 | <a href='./README_de.md'>Deutsch</a> | <a href='./README_es.md'>Español</a> | <a href='./README_ja.md'>日本語</a> | <a href='./README_hu.md'>Magyar</a> | <a href='./README_pt.md'>Português</a> | <a href='./README_tr.md'>Türkçe</a>
</p>

![Windows 上的 WSL Distro Manager，深色佈景主題](./images/home-dark.png)

<p align='center'>
    <sub>圖為 <b>Windows</b> 版 &middot; 同一套應用程式在 <b>macOS</b> 上執行原生虛擬機器 &mdash; 請展開下方的 <b>在 macOS 上的樣子</b></sub>
</p>

<details>
<summary>淺色佈景主題預覽（Windows）</summary>

![Windows 上的 WSL Distro Manager，淺色佈景主題](./images/home-light.png)

</details>

<details>
<summary><b>🍎 在 macOS 上的樣子</b> &mdash; 透過 Apple 的 Virtualization 框架執行原生 Linux 與 macOS 虛擬機器 <i>(beta)</i></summary>

![macOS 上的 WSL Manager，深色佈景主題](./images/home-macos-dark.png)

![macOS 上的 WSL Manager，淺色佈景主題，並開啟 AI 助理](./images/home-macos-light.png)

</details>

> **WSL Distro Manager** 是一套免費且開放原始碼的圖形介面工具，用來管理適用於
> Linux 的 Windows 子系統 —— 在 macOS 上則用來管理原生 Linux 虛擬機器。安裝、
> 複製、重新命名、搬移、備份與刪除 WSL 發行版，完全不必記住任何一個 `wsl.exe`
> 參數 —— 另外還有範本、已儲存的指令片段、磁碟掛載、`.wslconfig` 編輯、透過 SSH
> 管理遠端 WSL，以及一個可讓 AI 代理程式操作你的 WSL 環境的 MCP 伺服器。在 Mac
> 上，同一套應用程式改為透過 Apple 的 Virtualization 框架管理虛擬機器。

## 🚀 功能

**管理發行版**
- [x] 從內建目錄安裝，或使用你自己的 rootfs
- [x] 複製、重新命名、搬移到其他磁碟機、備份與刪除執行個體
- [x] 把所有安裝實體備份到一個資料夾（附帶內容清單），並在另一台電腦上還原
- [x] 壓縮虛擬磁碟，取回 WSL 從不歸還的空間
- [x] 即時查看某個執行個體正在使用的資源 —— 處理器、記憶體與交換空間，並附上動態圖表
- [x] 支援 Ubuntu、Debian、Alpine、Kali Linux、openSUSE、SLES，以及 WSL 接受的其他系統

**更快讓執行個體上線**
- [x] 把任何 Docker 映像檔當成發行版使用 —— 不需要安裝 Docker
- [x] 把設定好的發行版封裝成可攜的 `.wsl` 檔，於任何機器上安裝（範本已由它取代，不再建議使用）
- [x] Turnkey Linux 及其他 LXC 容器（實驗性）
- [x] 指令片段：把安裝設定指令保存在應用程式裡，並在任何執行個體上執行
- [x] 讓應用程式指向你自己的 rootfs 映像檔儲存庫
- [x] 瀏覽發行版中的檔案，把選取的複製到另一個安裝實體 — 不需共用、不需掛載、不需檔案總管

<!-- Unreleased. Containers, Kubernetes and Cloud are built but ship only in
     debug runs (LicenseManager.unreleasedFeaturesVisible, the gate Pro rides
     in a debug build); a release has none of them, so the README must not
     promise them. Lift the comment together with the gate.

**Docker 與 Podman 容器**
- [x] 在執行個體旁邊看到機器上的每一個容器 —— 兩種引擎同時呈現
- [x] 不必離開應用程式即可啟動、停止、重新啟動、移除容器並追蹤其記錄
- [x] 僅是前端：它驅動你既有的 `docker`/`podman`，不會安裝任何東西
- [x] AI 聊天與 MCP 伺服器取得同一套容器工具

**Kubernetes 叢集**
- [x] kubeconfig 中的每個叢集，一次專注一個命名空間 —— 為十個叢集、上百個應用而設計
- [x] Deployment、StatefulSet 與 DaemonSet 的健康狀態一目了然，可依名稱、命名空間或映像檔篩選
- [x] 開啟一個工作負載即可查看其 Pod、追蹤記錄、重新啟動某個 Pod、觸發滾動重啟、調整規模，或閱讀完整細節
- [x] 僅是前端：它驅動你既有的 `kubectl`，從不改寫 kubeconfig，也不切換你的 context
- [x] AI 聊天與 MCP 伺服器同樣能讀取你的叢集 —— 工作負載、Pod、事件、資源用量以及可搜尋的 Pod 日誌 —— 而且只能讀取：其中沒有任何工具可以重啟、擴縮或刪除

**部署到雲端** *(beta)*
- [x] 一步把整個執行個體推送到全新的 Hetzner Cloud 伺服器 —— 根檔案系統會被匯出、上傳，並在那裡以容器啟動
- [x] 伺服器由應用程式替你建立：規格、位置與基礎映像檔，並由 cloud-init 安裝 Docker、把你自己的 SSH 金鑰授權給 `root`
- [x] 在 macOS 上同樣可用：Linux 虛擬機器的根檔案系統是從執行中的客體讀出的，因為它的磁碟映像是一台可開機的機器，而不是容器引擎讀得懂的東西
- [x] 隨時把它當成新的本機執行個體拉回來，同時讓伺服器繼續運作 —— 在 macOS 上會還原到當初部署來源虛擬機器的副本中，該虛擬機器必須仍然存在且已停止，因為單有根檔案系統並沒有核心可供開機
- [x] 查看每台伺服器每月的費用，開機、關機，並在同一份清單中刪除它們
-->

**不必手動編輯檔案也能設定**
- [x] 逐個發行版設定 systemd、automount、預設使用者、啟動指令與啟動路徑
- [x] 記憶體、處理器、swap、網路模式、DNS 以及 `.wslconfig` 的其餘設定
- [x] 把實體磁碟或 VHD 掛載進 WSL，並可控制分割區與檔案系統
- [x] 將主機資料夾以你選擇的掛載點共用到發行版或虛擬機器中，可設為唯讀 — AI Workspace 同樣適用

**依照你原本的習慣工作**
- [x] 直接在發行版內開啟 Windows 終端機、VS Code 或檔案總管
- [x] 每個實例都出現在 Windows 終端機選單中，應用程式執行期間保持最新——以獨立的片段檔案加入，你的終端機設定不會被更動
- [x] 透過 SSH 管理*另一台* Windows 機器上的 WSL
- [x] 在網路上的兩台機器之間同步發行版
- [x] 用名稱存取實例：主機名稱會寫入 hosts 檔案，重新開機後 `ssh ubuntu.wsl` 依然可用
- [x] 自動保持最新：網站版與 GitHub 版會自行下載並安裝新版本（從商店安裝的版本由商店更新）
- [x] 深色與淺色佈景主題，提供九種語言

**在 macOS 上：原生虛擬機器** *(beta)*
- [x] 同一套應用程式改用 Apple 的 Virtualization 框架管理虛擬機器，而不是 WSL
- [x] 從安裝 ISO、雲端映像檔或匯出的範本建立 Linux 虛擬機器
- [x] 從還原映像檔建立 macOS 客體虛擬機器（Apple Silicon）
- [x] 像管理發行版一樣啟動、停止、複製、匯出／匯入虛擬機器並存成範本
- [x] 透過自動佈建的 SSH（cloud-init）在虛擬機器內執行指令，可來自圖形介面、AI 聊天或 MCP 用戶端
- [x] 在清單列中為任一虛擬機器開啟終端機：Linux 與 macOS 客體都走 SSH 工作階段，Linux 上無法連線時才退回序列主控台
- [x] 你自己的 `~/.ssh` 金鑰會被授權到每一台 Linux 虛擬機器（若你沒有則替你建立），所以單純執行 `ssh user@vm-ip` 也可以
- [x] 每台虛擬機器都有一組登入密碼，可在該列中讀回，用於在虛擬機器本身的畫面上登入
- [x] 可在同一列設定所有 SSH 方式登入時使用的帳戶 —— macOS 客體的使用者名稱在設定輔助程式中輸入，應用程式無從得知
- [x] 以 `scripts/build_macos.sh` 建置 —— 會封裝已簽署的 `vmctl` 協助程式

**Pro** *（一次性購買：Windows 上透過 Microsoft Store，macOS 與非商店安裝則於 [wslmanager.com/buy](https://wslmanager.com/buy/) 取得授權金鑰 —— 絕非訂閱制）*
- [x] **AI Workspace** —— 在專屬且隔離的 WSL 發行版中執行 Hermes Agent、OpenClaw、Open WebUI 與 OpenCode
- [x] **所有 AI 工具共用一套模型與端點** —— 設定中 AI 助理的 API 端點、金鑰和模型同樣用於 OpenCode、OpenClaw 與 Hermes；只需設定一次，之後安裝的工具也會自動取得
- [x] **具備工具的 AI 助理** —— 內建聊天能真正*操作*你的 WSL：它會列出並檢視發行版、執行指令、編輯設定、建立片段、掛載磁碟並封裝發行版，用的正是 MCP 伺服器所提供的同一套工具
- [x] **每次變更執行個體的 AI 執行都會儲存為片段** —— 記錄執行過的指令和各工具的回報，並從聊天中連結過去，方便你檢視、在新的執行個體上重新執行或分享
- [x] **沙箱 AI** —— 開一個用完即丟的 Ubuntu 發行版，並讓 AI 聊天*只能*存取該沙箱內部
- [x] **工作佇列** —— 把清單交給助理，讓它逐項完成並依序打勾
- [x] **MCP 伺服器** —— 把 WSL 提供給 Claude Desktop、Claude Code、opencode 及其他 MCP 用戶端
- [x] **網頁儀表板** —— 從手機或另一台電腦管理一切：掃描 QR code，在瀏覽器中取得整套應用程式，並可選擇透過 Cloudflare 通道發布到網路之外

> AI 功能使用**你自己**帶來的憑證 —— 你自己的 OpenAI 相容 API 金鑰。本應用程式不
> 代管也不附帶任何 AI 服務，沒有額度限制，也沒有任何請求會經過他人的伺服器。Pro
> 解鎖的是應用程式中的功能，而不是購買 AI 額度。請參閱
> [Free vs Pro](https://github.com/bostrot/wslmanager/wiki/Pro-Version)。

> **為什麼會有付費版？** 自 2021 年以來，WSL Manager 一直是一個人利用業餘時間做的
> 專案，上面的每一項功能 —— 包含免費的那些 —— 都是在晚上與週末寫出來的。管理你的
> 發行版與虛擬機器是免費的，而且會一直免費，整套應用程式也會維持開放原始碼。Pro
> 是疊在上面的 AI 層，它帶來的收入讓維護與新功能成為有計畫的常態工作，而不是只能
> 用剩下的時間去做。買一次，永遠擁有，你就是在直接資助下一個版本。

## 🤖 AI 助理與 MCP *(Pro)*

本節的所有內容都屬於 **Pro**；免費版並不包含其中任何一項。

AI 助理是一個**代理程式**，而不只是聊天框：它拿到的正是 MCP 伺服器提供的那套工具，
因此當你問「我有哪些發行版？」或說「安裝 Ubuntu 並設定我的預設使用者」時，它會對你的
WSL 呼叫真正的工具，而不是憑空猜測。工具呼叫會在它工作時就地顯示出來。

**設定服務供應商**：在**設定 → Bring Your Own AI Key**中，任何 OpenAI 相容端點都
可以（OpenAI、Azure、LiteLLM 代理、Ollama、LM Studio……）。輸入基底 URL、金鑰與模型。
**載入模型清單**按鈕會用供應商的 `/models` 填入自動完成，而**測試連線**則會在你開啟
聊天之前先證明憑證可用。

**一樣都不想要？** **設定 → Bring Your Own AI Key → AI 功能** 可以關閉助理、錯誤診斷和 AI Workspace —— 不會顯示任何與 AI 相關的內容，也不會為你準備工作區環境。在你作答之前它一直是關閉的：WSL Manager 只會在安裝或更新後的首次啟動時詢問一次，在那之前不會執行任何與 AI 相關的內容。

**沙箱**（AI Workspace → *新增沙箱發行版*）會從任何目錄映像檔（預設為最新的 Ubuntu）
建立一個用完即丟的執行個體 —— 在 Windows 上是 WSL 發行版，在 macOS 上則是以雲端映像檔
為種子的 Linux 虛擬機器，兩者都會替你建立並啟動。它的聊天只會拿到 `sandbox_*` 工具，
而且這些工具被鎖定在那一個執行個體上 —— 模型可以在沙箱*內部*做任何事，卻永遠看不到你
的主機或任何其他執行個體。一個誠實的但書：沙箱本身擁有正常的對外網際網路存取，就和
任何發行版或虛擬機器一樣。沙箱聊天與助理共用同一個停靠面板（含工作佇列），其對話記錄
會保留下來，而聊天標題列中的歷史按鈕可在助理與任何沙箱工作階段之間切換。

**工作佇列** —— 開啟聊天上方的*工作*區塊，加入項目，然後按 ▶。助理會用它的工具逐項
處理，並在完成時打勾；執行期間你仍可繼續加入工作。

### 連接外部 AI 用戶端（MCP）

開啟**設定 → MCP 伺服器**（Pro）。它會在 `http://127.0.0.1:59133/mcp` 提供 MCP 協定，
僅限回送位址，並由同一面板中顯示的 bearer 權杖保護。這些工具涵蓋完整生命週期 ——
建立、匯入、設定、執行、封裝，以及（在帶確認旗標時）取消註冊發行版，另外還有指令片段、
磁碟掛載與持續性終端機工作階段。

**Claude Desktop** —— 在 MCP 面板中點選**連接 Claude Desktop**。它會替你把下面的設定
寫入 `claude_desktop_config.json`（需要 Node.js）；之後請重新啟動 Claude Desktop。若要
手動設定，或用於任何其他 stdio MCP 用戶端，請用
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) 橋接該 HTTP 端點：

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

**Claude Code** —— 同樣的橋接，一行指令：

```bash
claude mcp add wsl-manager -- npx -y mcp-remote http://127.0.0.1:59133/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

**opencode** —— 在你的 `opencode.json`（或 `~/.config/opencode/opencode.json`）的 `mcp` 底下加入：

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

任何支援串流 HTTP 的 MCP 用戶端也可以直接指向該端點，只要帶上
`Authorization: Bearer <TOKEN>` 標頭，不必經過 `mcp-remote`。若要從另一台機器連上它，
請在同一面板啟用內建的 **Cloudflare 通道**開關，並使用它印出的公開 URL。

## 📱 網頁儀表板 *(Pro)*

開啟**設定 → 網頁儀表板**（Pro），應用程式就會在 `59134` 連接埠上，為你網路中的每一台
裝置提供瀏覽器儀表板 —— Windows 與 macOS 皆然。用手機掃描面板顯示的 QR code（或複製
連結），你就能在瀏覽器裡得到整套應用程式：啟動、停止、複製與刪除執行個體，執行指令，
開啟持續性終端機工作階段，執行已儲存的指令片段，並透過自動產生的表單使用其餘所有工具
（匯入、匯出、封裝、`.wslconfig`、磁碟、建立虛擬機器）。這與 AI 助理和 MCP 伺服器使用
的是同一套工具。

存取由連結中的權杖保護（`?token=…`），因此掃一個 QR code 就是裝置所需的全部 —— 而在
面板中重新產生權杖，會撤銷此前發出的每一個連結。這個儀表板刻意監聽所有網路介面；當你
不在家而需要暫時的公開 HTTPS 連結時，可在同一面板切換**透過 Cloudflare 通道發布**（QR
code 會隨之切換）。一旦發布，權杖就是保護這個能執行指令之介面的唯一屏障，所以請謹慎
分享該連結。

## 📦 安裝

<details>
<summary>Microsoft Store</summary>

本應用程式已上架 [Microsoft Store](https://apps.microsoft.com/store/detail/wsl-manager/9NWS9K95NMJB?hl=en-us&gl=US)。
</details>

<details>
<summary>macOS 透過 Homebrew 安裝</summary>

```sh
brew install --cask wsl-manager
```

Apple Silicon，macOS 11 或更新版本。該 cask 已隨 Homebrew 本體提供，不需要額外新增 tap；`brew upgrade --cask wsl-manager` 會取得新版本。
</details>

<details>
<summary>直接下載</summary>

你可以從 [Releases](https://github.com/bostrot/wslmanager/releases) 頁面直接下載本應用程式。Windows 提供安裝用的 `.exe`、`.msix` 與可攜式 `.zip`；macOS 則提供 `.dmg`。
</details>

<details>
<summary>透過 Winget 安裝</summary>

```sh
winget install Bostrot.WSLManager
```

</details>

<details>
<summary>透過 Scoop 安裝</summary>

```sh
scoop install extras/wsl2-distro-manager
```

</details>

<details>
<summary>透過 Chocolatey 安裝</summary>

此套件由社群維護（[@mikeee](https://github.com/mikeee/ChocoPackages)），並非官方套件。

```sh
choco install wsl2-distro-manager
```

</details>

<details>
<summary>安裝每夜建置版</summary>

最新的每夜建置版可在 “releaser” 工作流程的成品中取得，或透過[此連結](https://nightly.link/bostrot/wslmanager/workflows/releaser/main/wsl2-distro-manager-nightly-archive.zip)下載。

</details>

## ⚙️ 建置

請先確認已安裝 [flutter](https://flutter.dev/desktop)。

### Windows

```powershell
flutter config --enable-windows-desktop
flutter upgrade

flutter build windows # build it
flutter run -d windows # run it
```

### macOS

虛擬機器是由 `vmctl` 建立的 —— 那是一個驅動 Virtualization.framework 的小型 Swift
協助程式，而不是 Flutter 應用程式本身。該框架只回應帶有
`com.apple.security.virtualization` 授權的行程，而 `swift build` 不會加上它，因此
**必須先建置並簽署該協助程式，應用程式才能啟動虛擬機器**：

```bash
flutter config --enable-macos-desktop

# Build + sign vmctl and install it for dev runs. Re-run after any change
# under macos/vmctl/ — `flutter run` never rebuilds the helper.
VMCTL_ONLY=1 scripts/build_macos.sh

flutter run -d macos
```

跳過這一步，應用程式照樣能啟動，但啟動虛擬機器時會失敗並顯示：

```
VM failed to start: Error Domain=VZErrorDomain Code=2 "The process doesn't
have the "com.apple.security.virtualization" entitlement."
```

缺少授權的是*協助程式*，而不是應用程式 —— `Runner` 本身的授權原本就正確。簽署後的
協助程式會安裝到 `~/Library/Application Support/WSLManager/bin/vmctl`，偵錯執行正是
在那裡尋找；若沒有它，偵錯執行會退回到 `macos/vmctl/.build/` 底下未簽署的
`swift build` 產物，也就出現上面的錯誤。

不帶 `VMCTL_ONLY` 執行 `scripts/build_macos.sh` 會做同樣的簽署，接著建置發行版應用
程式，並把簽署後的協助程式封裝進 bundle 的 `Contents/Resources/`。建置應用程式本身
需要完整的 Xcode。

## 作者

👤 **Eric Trenkel**

- 網站：[erictrenkel.com](https://erictrenkel.com)
- GitHub：[@bostrot](https://github.com/bostrot)
- LinkedIn：[@erictrenkel](https://linkedin.com/in/erictrenkel)

👥 **貢獻者**

[![Contributors](https://contrib.rocks/image?repo=bostrot/wslmanager)](https://github.com/bostrot/wslmanager/graphs/contributors)

## 🤝 參與貢獻

歡迎貢獻程式碼、回報問題與提出功能需求！\
歡迎查看 [issues 頁面](https://github.com/bostrot/wslmanager/issues)。
你也可以看看[貢獻指南](https://github.com/bostrot/wslmanager/blob/main/CONTRIBUTING.md)。

## 支持這個專案

如果這個專案幫上了你，請給一顆 ⭐️！

## 📝 授權

版權所有 © 2026 [Eric Trenkel](https://github.com/bostrot)。\
本專案採用 [GPL-3.0](https://github.com/bostrot/wslmanager/blob/main/LICENSE) 授權。

---

_沒找到你想要的內容嗎？看看 [Wiki](https://github.com/bostrot/wslmanager/wiki)_
