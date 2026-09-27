<h1 align="center">WSL Manager へようこそ 👋</h1>

![GitHub Release Date](https://img.shields.io/github/release-date/bostrot/wslmanager?style=for-the-badge)
![GitHub Workflow](https://img.shields.io/github/actions/workflow/status/bostrot/wslmanager/releaser.yml?branch=main&label=nightly&style=for-the-badge)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/bostrot/wslmanager?style=for-the-badge)
[![Documentation](https://img.shields.io/badge/DOCUMENTATION-WIKI-green?style=for-the-badge)](https://github.com/bostrot/wslmanager/wiki)
[![GitLab stars](https://img.shields.io/gitlab/stars/bostrot/wsl2-distro-manager?gitlab_url=https%3A%2F%2Fgitlab.com&label=GitLab&style=for-the-badge)](https://gitlab.com/bostrot/wsl2-distro-manager)
[![Discord](https://img.shields.io/discord/1100070299308937287?style=for-the-badge)](https://discord.gg/fY5uE5WRTP)


<p align='center'>
    <a href='../README.md'>English</a> | <a href='./README_zh.md'>简体中文</a> | <a href='./README_zh_tw.md'>繁體中文</a> | <a href='./README_de.md'>Deutsch</a> | <a href='./README_es.md'>Español</a> | 日本語 | <a href='./README_hu.md'>Magyar</a> | <a href='./README_pt.md'>Português</a> | <a href='./README_tr.md'>Türkçe</a>
</p>

![Windows 上の WSL Distro Manager（ダークテーマ）](./images/home-dark.png)

<p align='center'>
    <sub>画面は <b>Windows</b> 版 &middot; 同じアプリが <b>macOS</b> ではネイティブ VM を動かします &mdash; 下の <b>macOS での画面</b> を開いてください</sub>
</p>

<details>
<summary>ライトテーマのプレビュー（Windows）</summary>

![Windows 上の WSL Distro Manager（ライトテーマ）](./images/home-light.png)

</details>

<details>
<summary><b>🍎 macOS での画面</b> &mdash; Apple の Virtualization フレームワークによるネイティブな Linux／macOS 仮想マシン <i>(ベータ)</i></summary>

![macOS 上の WSL Manager（ダークテーマ）](./images/home-macos-dark.png)

![macOS 上の WSL Manager（ライトテーマ、AI アシスタントを開いた状態）](./images/home-macos-light.png)

</details>

> **WSL Distro Manager** は、Windows Subsystem for Linux のための、そして macOS
> ではネイティブな Linux VM のための、無料でオープンソースの GUI です。`wsl.exe`
> のオプションを 1 つも覚えることなく、WSL ディストリビューションのインストール、
> コピー、名前変更、移動、バックアップ、削除ができます。さらにテンプレート、保存
> したコマンドスニペット、ディスクのマウント、`.wslconfig` の編集、SSH 経由の
> リモート WSL、そして AI エージェントに WSL 環境を操作させる MCP サーバーも備え
> ています。Mac ではまったく同じアプリが、代わりに Apple の Virtualization
> フレームワークで仮想マシンを管理します。

## 🚀 機能

**ディストリビューションの管理**
- [x] 組み込みのカタログからインストール、または自前の rootfs を持ち込み
- [x] インスタンスのコピー、名前変更、別ドライブへの移動、バックアップ、削除
- [x] すべてのインスタンスを 1 つのフォルダーにバックアップし（内容の一覧付き）、別の PC で復元
- [x] 仮想ディスクを圧縮し、WSL が決して返さない領域を取り戻す
- [x] インスタンスが今使っているもの（CPU 時間・メモリ・スワップ）をライブグラフで確認
- [x] Ubuntu、Debian、Alpine、Kali Linux、openSUSE、SLES など、WSL が受け付けるものすべてに対応

**インスタンスをより速く動かす**
- [x] 任意の Docker イメージをディストリビューションとして利用 —— Docker 自体は不要
- [x] 設定済みのディストリビューションを、どのマシンにでもインストールできる可搬な `.wsl` ファイルとしてパッケージ化（テンプレートはこれに置き換えられ非推奨）
- [x] Turnkey Linux やその他の LXC コンテナ（実験的）
- [x] スニペット: セットアップ用のコマンドをアプリ内に保存し、任意のインスタンスで実行
- [x] 自分の rootfs イメージリポジトリをアプリに指定
- [x] ディストロのファイルを一覧し、選んだものを別のインスタンスにコピー — 共有もマウントもエクスプローラーも不要

<!-- Unreleased. Containers, Kubernetes and Cloud are built but ship only in
     debug runs (LicenseManager.unreleasedFeaturesVisible, the gate Pro rides
     in a debug build); a release has none of them, so the README must not
     promise them. Lift the comment together with the gate.

**Docker と Podman のコンテナ**
- [x] マシン上のすべてのコンテナを —— 両エンジンを同時に —— インスタンスの隣に表示
- [x] アプリを離れずにコンテナの起動、停止、再起動、削除、ログの追尾ができる
- [x] フロントエンドに徹する: すでにある `docker`/`podman` を操作するだけで、何もインストールしない
- [x] AI チャットと MCP サーバーも同じコンテナツールを利用できる

**Kubernetes クラスター**
- [x] kubeconfig にあるすべてのクラスターを、名前空間ごとに —— 100 のアプリを抱える 10 クラスターを想定した設計
- [x] Deployment、StatefulSet、DaemonSet の健全性がひと目で分かり、名前・名前空間・イメージで絞り込み可能
- [x] ワークロードを開けば Pod を確認し、ログを追尾し、Pod を再起動し、ローリング再起動をかけ、スケールし、詳細をすべて読める
- [x] フロントエンドに徹する: すでにある `kubectl` を操作するだけで、kubeconfig を書き換えたりコンテキストを切り替えたりしない
- [x] AI チャットと MCP サーバーもクラスターを読める —— ワークロード、Pod、イベント、リソース使用量、検索できる Pod ログ —— 読むだけで、再起動・スケール・削除は一切できない

**クラウドへのデプロイ** *(ベータ)*
- [x] インスタンス丸ごとを新規の Hetzner Cloud サーバーへワンステップで送り出す —— ルートファイルシステムがエクスポートされ、アップロードされ、そこでコンテナとして起動する
- [x] サーバーは自動で作成: サイズ、ロケーション、ベースイメージを選び、cloud-init が Docker を入れて自分の SSH 鍵を `root` に許可する
- [x] macOS からも利用可能: Linux VM のルートファイルシステムは動作中のゲストから読み出す。ディスクイメージは起動可能なマシンであって、コンテナエンジンが読める代物ではないため
- [x] サーバーを動かしたまま、いつでも新しいローカルインスタンスとして引き戻せる —— macOS ではデプロイ元 VM のコピーへ復元されるため、その VM が存在し停止している必要がある。ルートファイルシステムだけでは起動するカーネルがないからだ
- [x] 各サーバーの月額を確認し、電源を入れたり切ったり、同じ一覧から削除したりできる
-->

**ファイルを手で編集せずに設定**
- [x] ディストリビューションごとの systemd、automount、既定ユーザー、起動コマンド、起動パス
- [x] メモリ、プロセッサ、スワップ、ネットワークモード、DNS など `.wslconfig` の設定一式
- [x] 物理ディスクや VHD を WSL にマウント（パーティションとファイルシステムも指定可能）
- [x] ホストのフォルダーを任意のマウントポイントでディストロや VM に共有（読み取り専用も可）— AI Workspace でも利用可能

**いつものやり方のままで**
- [x] Windows ターミナル、VS Code、エクスプローラーをディストリビューション内で直接開く
- [x] すべてのインスタンスを Windows ターミナルのメニューに表示し、アプリの実行中は最新に保つ — 専用のフラグメントとして追加されるため、ターミナルの設定は変更されません
- [x] *別の* Windows マシン上の WSL を SSH 経由で管理
- [x] ネットワーク上の 2 台のマシン間でディストリビューションを同期
- [x] インスタンスに名前で接続: ホスト名が hosts ファイルに保たれるので、再起動後も `ssh ubuntu.wsl` が使えます
- [x] 自動で最新に保つ: ウェブサイト版と GitHub 版は新しいリリースを自分でダウンロードしてインストールする（ストア版はストアが更新）
- [x] ダーク／ライトテーマ、9 言語に対応

**macOS では: ネイティブな仮想マシン** *(ベータ)*
- [x] 同じアプリが WSL の代わりに Apple の Virtualization フレームワークで VM を管理
- [x] インストーラー ISO、クラウドイメージ、エクスポートしたテンプレートから Linux VM を作成
- [x] リストアイメージから macOS ゲスト VM を作成（Apple シリコン）
- [x] ディストリビューションと同じように VM を起動、停止、複製、エクスポート／インポート、テンプレート化
- [x] 自動プロビジョニングされた SSH（cloud-init）経由で、GUI・AI チャット・MCP クライアントから VM 内のコマンドを実行
- [x] 一覧の行からどの VM でも端末を開ける: Linux でも macOS ゲストでも SSH セッション、Linux で接続先がないときはシリアルコンソール
- [x] 自分の `~/.ssh` 鍵がすべての Linux VM で許可される（鍵がなければ作成される）ので、素の `ssh user@vm-ip` も使える
- [x] どの VM にもログインパスワードが割り当てられ、その行から読み出せる。VM 自身の画面でサインインするために使う
- [x] すべての SSH 経路がどのアカウントでサインインするかを同じ行から設定できる。macOS ゲストの名前は設定アシスタントで入力され、アプリからは見えないため
- [x] `scripts/build_macos.sh` でビルド —— 署名済みの `vmctl` ヘルパーを同梱する

**Pro** *（買い切り: Windows は Microsoft Store、macOS とストア外インストールは [wslmanager.com/buy](https://wslmanager.com/buy/) のライセンスキー —— サブスクリプションではありません）*
- [x] **AI Workspace** —— 専用に隔離された WSL ディストリビューションで Hermes Agent、OpenClaw、Open WebUI、OpenCode を実行
- [x] **すべての AI ツールに共通のモデルとエンドポイント** —— 設定にあるアシスタントの API エンドポイント、キー、モデルを OpenCode、OpenClaw、Hermes もそのまま使う。一度設定するだけで、後からインストールしたツールにも引き継がれる
- [x] **ツールを持つ AI アシスタント** —— 組み込みチャットが実際に WSL を*操作*できる。MCP サーバーが公開するのと同じツールを使って、ディストリビューションの一覧表示と調査、コマンド実行、設定の編集、スニペットの作成、ディスクのマウント、パッケージ化を行う
- [x] **インスタンスを変更した AI の実行はすべてスニペットとして保存** —— 実行したコマンドと各ツールの報告内容を記録し、チャットからリンクされるので、後から確認したり、新しいインスタンスで再実行したり、共有したりできる
- [x] **サンドボックス AI** —— 使い捨ての Ubuntu ディストリビューションを立ち上げ、AI チャットにそのサンドボックスの*内側だけ*へのアクセスを与える
- [x] **タスクキュー** —— やることリストを渡せば、アシスタントが順に片付けてチェックを付けていく
- [x] **MCP サーバー** —— Claude Desktop、Claude Code、opencode などの MCP クライアントに WSL を公開
- [x] **Web ダッシュボード** —— スマートフォンや別のコンピューターからすべてを管理。QR コードを読み取ればブラウザーでアプリ全体が使え、必要なら Cloudflare トンネルでネットワークの外にも公開できる

> AI 機能は**あなた自身**が用意した資格情報 —— あなた自身の OpenAI 互換 API キー
> —— で動きます。AI サービスをホストすることも同梱することもなく、利用枠もなく、
> リクエストが誰かのサーバーを経由することもありません。Pro が解除するのはアプリ
> 内の機能であって、AI のクレジットを買うものではありません。
> [Free vs Pro](https://github.com/bostrot/wslmanager/wiki/Pro-Version) を
> ご覧ください。

> **そもそもなぜ有料版があるのか？** WSL Manager は 2021 年から続く、一人が余暇に
> 作っているプロジェクトで、上に挙げた機能は —— 無料のものも含めて —— すべて夜と
> 週末に書かれました。ディストリビューションと VM の管理は無料で、これからも無料
> です。アプリ全体もオープンソースのままです。Pro はその上に乗る AI レイヤーであり、
> そこから得られるものが、保守と新機能を「余った時間でやること」から「計画された
> 定期的な仕事」へと変えてくれます。一度買えばずっと使えて、次のリリースを直接
> 支えることになります。

> 🎁 **ローンチ特典 —— 先着 100 名は Pro が無料。** `START100` があらかじめ適用
> された決済ページを開けば、次のページにライセンスキーが表示されます:
> [**Windows**](https://buy.stripe.com/5kQeVd6ECgur3wJ2TO1Fe03?prefilled_promo_code=START100) ·
> [**macOS**](https://buy.stripe.com/dRm00jbYWfqnaZb1PK1Fe02?prefilled_promo_code=START100)。
> 1 人 1 ライセンス。100 名に達するとコードは使えなくなります。

## 🤖 AI アシスタントと MCP *(Pro)*

このセクションの内容はすべて **Pro** のものです。無料版にはひとつも含まれません。

AI アシスタントは単なるチャット欄ではなく**エージェント**です。MCP サーバーが公開
するのと同じツール一式を渡されているので、「どんなディストリビューションがある？」
「Ubuntu を入れて既定ユーザーを設定して」と頼めば、推測ではなく実際のツールを
あなたの WSL に対して呼び出します。ツール呼び出しは作業中にその場で表示されます。

**プロバイダーの設定**は **設定 → Bring Your Own AI Key** で行います。OpenAI 互換の
エンドポイントであれば何でも使えます（OpenAI、Azure、LiteLLM プロキシ、Ollama、
LM Studio など）。ベース URL、キー、モデルを入力してください。**モデル一覧を読み込む**
ボタンはプロバイダーの `/models` からオートコンプリートを埋め、**接続テスト**は
チャットを開く前に資格情報が有効であることを確かめます。

**どれも要らない場合は** **設定 → Bring Your Own AI Key → AI 機能** をオフにしてください。アシスタント、エラー診断、AI Workspace が無効になり、AI 関連のものは何も表示されず、ワークスペース環境も自動では用意されません。回答するまではオフのままで、WSL Manager はインストールまたは更新後の最初の起動時に一度だけ確認します。それまでは AI 関連のものは何も動きません。

**サンドボックス**（AI Workspace → *サンドボックスディストリビューションを追加*）は、
任意のカタログイメージ（既定では最新の Ubuntu）から使い捨てのインスタンスを作ります。
Windows では WSL ディストリビューション、macOS ではクラウドイメージを元にした Linux
VM が、作成され起動されます。そのチャットに渡されるのは `sandbox_*` ツールだけで、
これらはその 1 つのインスタンスに固定されています —— モデルはサンドボックスの*内側*
では何でもできますが、ホストや他のインスタンスを見ることは決してできません。正直に
言えば 1 つだけ注意があります: サンドボックス自体は、他のディストリビューションや VM
と同様に通常どおり外向きのインターネット接続を持ちます。サンドボックスのチャットは
アシスタントと同じドッキングパネル（タスクキューを含む）を使い、その履歴は保存され、
チャットヘッダーの履歴ボタンでアシスタントと各サンドボックスセッションを切り替えられ
ます。

**タスクキュー** —— チャット上部の*タスク*セクションを開き、項目を追加して ▶ を押します。
アシスタントはツールを使って順に処理し、終わるたびにチェックを付けます。実行中でも
タスクを追加できます。

### 外部 AI クライアントの接続（MCP）

**設定 → MCP サーバー**（Pro）をオンにします。`http://127.0.0.1:59133/mcp` で MCP
プロトコルを提供し、ループバック専用で、同じパネルに表示されるベアラートークンで保護
されます。ツールはライフサイクル全体をカバーします —— ディストリビューションの作成、
インポート、設定、実行、パッケージ化、そして（確認フラグ付きで）登録解除に加え、
スニペット、ディスクのマウント、永続的なターミナルセッションです。

**Claude Desktop** —— MCP パネルの **Claude Desktop に接続** をクリックします。下の
エントリを `claude_desktop_config.json` に書き込んでくれます（Node.js が必要）。その後
Claude Desktop を再起動してください。手動で行う場合や、他の stdio MCP クライアントの
場合は、[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) で HTTP エンドポイント
をブリッジします:

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

**Claude Code** —— 同じブリッジを、コマンド 1 つで:

```bash
claude mcp add wsl-manager -- npx -y mcp-remote http://127.0.0.1:59133/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

**opencode** —— `opencode.json`（または `~/.config/opencode/opencode.json`）の `mcp` の下に追加します:

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

ストリーミング HTTP を話す MCP クライアントであれば、`mcp-remote` を挟まずに
`Authorization: Bearer <TOKEN>` ヘッダーを付けてエンドポイントへ直接つなぐこともできます。
別のマシンから到達したい場合は、同じパネルで組み込みの **Cloudflare トンネル** を有効に
して、表示された公開 URL を使ってください。

## 📱 Web ダッシュボード *(Pro)*

**設定 → Web ダッシュボード**（Pro）をオンにすると、アプリはネットワーク上のあらゆる
デバイス向けに、ポート `59134` でブラウザーダッシュボードを提供します —— Windows でも
macOS でも同じです。パネルに表示される QR コードをスマートフォンで読み取る（またはリンク
をコピーする）と、ブラウザーでアプリ全体が使えます: インスタンスの起動・停止・複製・削除、
コマンドの実行、永続的なターミナルセッションの利用、保存したスニペットの実行、そして
生成されたフォームによるその他すべてのツール（インポート、エクスポート、パッケージ化、
`.wslconfig`、ディスク、VM 作成）の操作です。AI アシスタントや MCP サーバーが使うのと
同じツール一式です。

アクセスはリンクに含まれるトークン（`?token=…`）で守られているため、QR コードを読み取る
だけでデバイスは接続できます。パネルでトークンを再生成すれば、それまでに配ったリンクは
すべて無効になります。ダッシュボードは意図してすべてのインターフェースで待ち受けます。
外出先で必要なときは、同じパネルの **Cloudflare トンネルで公開** を切り替えると、一時的な
公開 HTTPS リンクが得られます（QR コードもそちらに切り替わります）。公開したあとは、
コマンドを実行できる画面を守るのはトークンだけになるので、そのリンクの共有には注意して
ください。

## 📦 インストール

<details>
<summary>Microsoft Store</summary>

このアプリは [Microsoft Store](https://apps.microsoft.com/store/detail/wsl-manager/9NWS9K95NMJB?hl=en-us&gl=US) で入手できます。
</details>

<details>
<summary>macOS（Homebrew）</summary>

```sh
brew install --cask wsl-manager
```

Apple シリコン、macOS 11 以降。cask は Homebrew 本体に含まれているため、tap は不要です。`brew upgrade --cask wsl-manager` で新しいリリースを取得できます。
</details>

<details>
<summary>直接ダウンロード</summary>

このアプリは [Releases](https://github.com/bostrot/wslmanager/releases) ページから直接ダウンロードできます。Windows 版はセットアップ `.exe`、`.msix`、ポータブルな `.zip` で、macOS 版は `.dmg` で配布しています。
</details>

<details>
<summary>Winget でインストール</summary>

```sh
winget install Bostrot.WSLManager
```

</details>

<details>
<summary>Scoop でインストール</summary>

```sh
scoop install extras/wsl2-distro-manager
```

</details>

<details>
<summary>Chocolatey でインストール</summary>

このパッケージはコミュニティ（[@mikeee](https://github.com/mikeee/ChocoPackages)）が管理しています。公式パッケージではありません。

```sh
choco install wsl2-distro-manager
```

</details>

<details>
<summary>ナイトリービルドのインストール</summary>

最新のナイトリービルドは「releaser」ワークフローの成果物として、または[このリンク](https://nightly.link/bostrot/wslmanager/workflows/releaser/main/wsl2-distro-manager-nightly-archive.zip)から入手できます。

</details>

## ⚙️ ビルド

[flutter](https://flutter.dev/desktop) がインストールされていることを確認してください。

### Windows

```powershell
flutter config --enable-windows-desktop
flutter upgrade

flutter build windows # build it
flutter run -d windows # run it
```

### macOS

VM を作るのは Flutter アプリ本体ではなく、Virtualization.framework を操作する小さな
Swift ヘルパー `vmctl` です。このフレームワークは `com.apple.security.virtualization`
の entitlement を持つプロセスにしか応答せず、`swift build` はそれを付けません。
つまり **アプリが VM を起動できるようになる前に、ヘルパーをビルドして署名しておく
必要があります**:

```bash
flutter config --enable-macos-desktop

# Build + sign vmctl and install it for dev runs. Re-run after any change
# under macos/vmctl/ — `flutter run` never rebuilds the helper.
VMCTL_ONLY=1 scripts/build_macos.sh

flutter run -d macos
```

この手順を飛ばしてもアプリ自体は問題なく起動しますが、VM の起動は次のエラーで失敗します:

```
VM failed to start: Error Domain=VZErrorDomain Code=2 "The process doesn't
have the "com.apple.security.virtualization" entitlement."
```

entitlement が足りないのはアプリではなく*ヘルパー*です —— `Runner` 自身の entitlement
はすでに正しく設定されています。署名済みのヘルパーは
`~/Library/Application Support/WSLManager/bin/vmctl` にインストールされ、デバッグ実行は
そこを見ます。これがないと `macos/vmctl/.build/` にある未署名の `swift build` の出力に
フォールバックし、上のエラーが出ます。

`VMCTL_ONLY` なしで `scripts/build_macos.sh` を実行すると、同じ署名を行ったうえで
リリース版アプリをビルドし、署名済みヘルパーをバンドルの `Contents/Resources/` に同梱
します。アプリ自体のビルドには完全版の Xcode が必要です。

## 著者

👤 **Eric Trenkel**

- ウェブサイト: [erictrenkel.com](https://erictrenkel.com)
- GitHub: [@bostrot](https://github.com/bostrot)
- LinkedIn: [@erictrenkel](https://linkedin.com/in/erictrenkel)

👥 **コントリビューター**

[![Contributors](https://contrib.rocks/image?repo=bostrot/wslmanager)](https://github.com/bostrot/wslmanager/graphs/contributors)

## 🤝 コントリビューション

コントリビューション、Issue、機能リクエストを歓迎します！\
[Issue ページ](https://github.com/bostrot/wslmanager/issues)もぜひご覧ください。
[コントリビューションガイド](https://github.com/bostrot/wslmanager/blob/main/CONTRIBUTING.md)も参考になります。

## サポートを示す

このプロジェクトが役に立ったら ⭐️ をお願いします！

## 📝 ライセンス

Copyright © 2026 [Eric Trenkel](https://github.com/bostrot).\
このプロジェクトは [GPL-3.0](https://github.com/bostrot/wslmanager/blob/main/LICENSE) ライセンスです。

---

_お探しのものが見つかりませんでしたか？ [Wiki](https://github.com/bostrot/wslmanager/wiki) をご覧ください_
