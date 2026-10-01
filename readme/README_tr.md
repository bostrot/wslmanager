<h1 align="center">WSL Manager'a hoş geldiniz 👋</h1>

![GitHub Release Date](https://img.shields.io/github/release-date/bostrot/wslmanager?style=for-the-badge)
![GitHub Workflow](https://img.shields.io/github/actions/workflow/status/bostrot/wslmanager/releaser.yml?branch=main&label=nightly&style=for-the-badge)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/bostrot/wslmanager?style=for-the-badge)
[![Documentation](https://img.shields.io/badge/DOCUMENTATION-WIKI-green?style=for-the-badge)](https://github.com/bostrot/wslmanager/wiki)
[![GitLab stars](https://img.shields.io/gitlab/stars/bostrot/wsl2-distro-manager?gitlab_url=https%3A%2F%2Fgitlab.com&label=GitLab&style=for-the-badge)](https://gitlab.com/bostrot/wsl2-distro-manager)
[![Discord](https://img.shields.io/discord/1100070299308937287?style=for-the-badge)](https://discord.gg/fY5uE5WRTP)


<p align='center'>
    <a href='../README.md'>English</a> | <a href='./README_zh.md'>简体中文</a> | <a href='./README_zh_tw.md'>繁體中文</a> | <a href='./README_de.md'>Deutsch</a> | <a href='./README_es.md'>Español</a> | <a href='./README_ja.md'>日本語</a> | <a href='./README_hu.md'>Magyar</a> | <a href='./README_pt.md'>Português</a> | Türkçe
</p>

![Windows üzerinde WSL Distro Manager, koyu tema](./images/home-dark.png)

<p align='center'>
    <sub><b>Windows</b> üzerinde gösteriliyor &middot; aynı uygulama <b>macOS</b> üzerinde yerel sanal makineler çalıştırır &mdash; aşağıdaki <b>macOS üzerinde görün</b> bölümünü açın</sub>
</p>

<details>
<summary>Açık tema önizlemesi (Windows)</summary>

![Windows üzerinde WSL Distro Manager, açık tema](./images/home-light.png)

</details>

<details>
<summary><b>🍎 macOS üzerinde görün</b> &mdash; Apple'ın Virtualization çerçevesiyle yerel Linux ve macOS sanal makineleri <i>(beta)</i></summary>

![macOS üzerinde WSL Manager, koyu tema](./images/home-macos-dark.png)

![macOS üzerinde WSL Manager, açık tema, yapay zekâ asistanı açıkken](./images/home-macos-light.png)

</details>

> **WSL Distro Manager**, Linux için Windows Alt Sistemi'ne — ve macOS'ta yerel
> Linux sanal makinelerine — yönelik ücretsiz, açık kaynaklı bir grafik
> arayüzdür. Tek bir `wsl.exe` parametresini bile ezberlemeden WSL dağıtımlarını
> kurun, kopyalayın, yeniden adlandırın, taşıyın, yedekleyin ve silin — ayrıca
> şablonlar, kaydedilmiş komut parçacıkları, disk bağlama, `.wslconfig` düzenleme,
> SSH üzerinden uzak WSL ve yapay zekâ aracılarının WSL ortamınızı kullanmasını
> sağlayan bir MCP sunucusu. Mac'te ise aynı uygulama, bunun yerine Apple'ın
> Virtualization çerçevesiyle sanal makineleri yönetir.

## 🚀 Özellikler

**Dağıtımları yönetin**
- [x] Yerleşik katalogdan kurun ya da kendi rootfs'inizi getirin
- [x] Örnekleri kopyalayın, yeniden adlandırın, başka bir sürücüye taşıyın, yedekleyin ve silin
- [x] Tüm dağıtımları tek bir klasöre yedekleyin — içindekilerin listesiyle birlikte — ve başka bir bilgisayarda geri yükleyin
- [x] WSL'in asla geri vermediği alanı geri kazanmak için sanal diskleri sıkıştırın
- [x] Bir örneğin şu anda ne kullandığını görün — işlemci, bellek ve takas, canlı grafikle
- [x] Ubuntu, Debian, Alpine, Kali Linux, openSUSE, SLES ve WSL'in kabul ettiği her şeyi destekler

**Örnekleri daha hızlı çalışır hale getirin**
- [x] Herhangi bir Docker imajını dağıtım olarak kullanın — Docker'ın kendisi gerekmez
- [x] Yapılandırılmış bir dağıtımı, her makineye kurulabilen taşınabilir bir `.wsl` dosyası olarak paketleyin (şablonlar bunun lehine kullanımdan kaldırıldı)
- [x] Turnkey Linux ve diğer LXC kapsayıcıları (deneysel)
- [x] Parçacıklar: kurulum komutlarınızı uygulamada saklayın ve herhangi bir örnekte çalıştırın
- [x] Uygulamayı kendi rootfs imaj deponuza yönlendirin
- [x] Bir dağıtımın dosyalarına göz atın ve seçtiklerinizi başka bir dağıtıma kopyalayın — paylaşım, bağlama veya Dosya Gezgini gerekmeden

<!-- Unreleased. Containers, Kubernetes and Cloud are built but ship only in
     debug runs (LicenseManager.unreleasedFeaturesVisible, the gate Pro rides
     in a debug build); a release has none of them, so the README must not
     promise them. Lift the comment together with the gate.

**Docker ve Podman kapsayıcıları**
- [x] Makinedeki her kapsayıcıyı — iki motoru da aynı anda — örneklerinizin yanında görün
- [x] Uygulamadan çıkmadan bir kapsayıcıyı başlatın, durdurun, yeniden başlatın, kaldırın ve günlüklerini izleyin
- [x] Yalnızca ön yüz: zaten kurulu olan `docker`/`podman` komutunuzu kullanır ve hiçbir şey kurmaz
- [x] Yapay zekâ sohbeti ve MCP sunucusu aynı kapsayıcı araçlarını alır

**Kubernetes kümeleri**
- [x] kubeconfig'inizdeki her küme, bir seferde tek ad alanı — yüz uygulamalı on küme için tasarlandı
- [x] Deployment, StatefulSet ve DaemonSet'ler tek bakışta sağlık durumuyla, ada, ad alanına veya imaja göre filtrelenmiş halde
- [x] Bir iş yükünü açıp pod'larını görün, günlüklerini izleyin, bir pod'u yeniden başlatın, rollout restart yapın, ölçeklendirin veya tüm ayrıntıları okuyun
- [x] Yalnızca ön yüz: zaten kurulu olan `kubectl` komutunuzu kullanır, kubeconfig'inizi asla yeniden yazmaz ve bağlamınızı değiştirmez
- [x] Yapay zekâ sohbeti ve MCP sunucusu da kümelerinizi okur — iş yükleri, podlar, olaylar, kaynak kullanımı ve aranabilir pod günlükleri — ve yalnızca okur: hiçbiri yeniden başlatamaz, ölçekleyemez veya silemez

**Buluta dağıtın** *(beta)*
- [x] Bütün bir örneği tek adımda yepyeni bir Hetzner Cloud sunucusuna gönderin — kök dosya sistemi dışa aktarılır, yüklenir ve orada kapsayıcı olarak başlatılır
- [x] Sunucu sizin için oluşturulur: boyut, konum ve temel imaj; cloud-init Docker'ı kurar ve kendi SSH anahtarınızı `root` için yetkilendirir
- [x] macOS'tan da çalışır: bir Linux sanal makinesinin kök dosya sistemi çalışan konuktan okunur, çünkü disk imajı önyüklenebilir bir makinedir, bir kapsayıcı motorunun okuyabileceği bir şey değil
- [x] Sunucu çalışmaya devam ederken istediğiniz zaman yeni bir yerel örnek olarak geri çekin — macOS'ta bu, dağıtımın yapıldığı sanal makinenin bir kopyasına geri yüklenir; o makinenin hâlâ var olması ve durdurulmuş olması gerekir, çünkü çıplak bir kök dosya sisteminin önyükleyecek çekirdeği yoktur
- [x] Her sunucunun aylık maliyetini görün, açıp kapatın ve aynı listeden silin
-->

**Dosyaları elle düzenlemeden yapılandırın**
- [x] Dağıtım başına systemd, automount, varsayılan kullanıcı, başlangıç komutu ve başlangıç yolu
- [x] Bellek, işlemciler, takas, ağ modu, DNS ve `.wslconfig`'in geri kalanı
- [x] Fiziksel bir diski ya da bir VHD'yi bölüm ve dosya sistemi denetimiyle WSL'e bağlayın
- [x] Ana makine klasörlerini seçtiğiniz bağlama noktasında bir dağıtıma veya VM'ye paylaşın, isterseniz salt okunur — AI Workspace dahil

**Zaten çalıştığınız gibi çalışın**
- [x] Windows Terminal'i, VS Code'u veya Dosya Gezgini'ni doğrudan bir dağıtımın içinde açın
- [x] Her örnek Windows Terminal menüsünde, uygulama açıkken güncel tutulur — kendi parçası olarak eklenir, böylece Terminal ayarlarınıza hiç dokunulmaz
- [x] *Başka* bir Windows makinesindeki WSL'i SSH üzerinden yönetin
- [x] Ağınızdaki iki makine arasında bir dağıtımı eşitleyin
- [x] Bir örneğe adıyla erişin: ana makine adı hosts dosyasında güncel tutulur, böylece `ssh ubuntu.wsl` yeniden başlatmadan sonra da çalışır
- [x] Kendini güncel tutar: web sitesi ve GitHub sürümleri yeni sürümleri kendisi indirip kurar (Store kurulumlarını Store günceller)
- [x] Koyu ve açık temalar, dokuz dilde kullanılabilir

**macOS'ta: yerel sanal makineler** *(beta)*
- [x] Aynı uygulama, WSL yerine Apple'ın Virtualization çerçevesiyle sanal makineleri yönetir
- [x] Kurulum ISO'sundan, bir bulut imajından veya dışa aktarılmış bir şablondan Linux sanal makineleri oluşturun
- [x] Bir kurtarma imajından macOS konuk sanal makineleri oluşturun (Apple Silicon)
- [x] Sanal makineleri dağıtımlar gibi başlatın, durdurun, klonlayın, dışa/içe aktarın ve şablonlaştırın
- [x] Otomatik hazırlanan SSH (cloud-init) üzerinden sanal makinelerin içinde komut çalıştırın; arayüzden, yapay zekâ sohbetinden veya MCP istemcilerinden
- [x] Her sanal makineye kendi satırından bir terminal: Linux veya macOS konuğunda bir SSH oturumu, Linux'ta bağlanacak bir şey yoksa seri konsol
- [x] Kendi `~/.ssh` anahtarınız her Linux sanal makinesinde yetkilendirilir (yoksa oluşturulur), böylece düz `ssh kullanici@vm-ip` de çalışır
- [x] Her sanal makine, satırından okuyabileceğiniz bir oturum açma parolası alır; makinenin kendi ekranından giriş yapmak için
- [x] Her SSH yolunun hangi hesapla oturum açacağını aynı satırdan ayarlayın — macOS konuğunun adı, uygulamanın göremediği Kurulum Yardımcısı'na yazılır
- [x] `scripts/build_macos.sh` ile derleyin — imzalı `vmctl` yardımcısını paketler

**Pro** *(tek seferlik satın alma: Windows'ta Microsoft Store, macOS ve Store dışı kurulumlar için [wslmanager.com/buy](https://wslmanager.com/buy/) adresinden lisans anahtarı — asla abonelik değil)*
- [x] **AI Workspace** — Hermes Agent, OpenClaw, Open WebUI ve OpenCode'u ayrılmış, yalıtılmış bir WSL dağıtımında çalıştırın
- [x] **Tüm yapay zekâ araçları için tek model ve uç nokta** — Ayarlar'daki asistan API uç noktası, anahtarı ve modeli OpenCode, OpenClaw ve Hermes tarafından da kullanılır; bir kez ayarlayın, sonradan kurulan araçlar da bunları alır
- [x] **Araçlı yapay zekâ asistanı** — yerleşik sohbet WSL'inizi gerçekten *kullanabilir*: MCP sunucusunun sunduğu araçların aynısıyla dağıtımları listeler ve inceler, komut çalıştırır, yapılandırmayı düzenler, parçacık oluşturur, disk bağlar ve dağıtım paketler
- [x] **Bir örneği değiştiren her yapay zekâ çalıştırması parçacık olarak kaydedilir** — çalıştırılan komutlar ve her aracın bildirdikleriyle birlikte, sohbetten bağlantılı; böylece inceleyebilir, yeni bir örnekte yeniden çalıştırabilir veya paylaşabilirsiniz
- [x] **Kum havuzunda yapay zekâ** — tek kullanımlık bir Ubuntu dağıtımı ayağa kaldırın ve bir yapay zekâ sohbetine *yalnızca* o kum havuzunun içine erişim verin
- [x] **Görev kuyruğu** — asistana bir kontrol listesi verin, o da araçlarıyla ilerledikçe maddeleri işaretleyerek listeyi bitirsin
- [x] **MCP sunucusu** — WSL'i Claude Desktop, Claude Code, opencode ve diğer MCP istemcilerine açın
- [x] **Web panosu** — her şeyi telefonunuzdan veya başka bir bilgisayardan yönetin: bir QR kodu okutun, uygulamanın tamamını tarayıcıda kullanın, isterseniz bir Cloudflare tüneliyle ağınızın dışına yayımlayın

> Yapay zekâ özellikleri **sizin** getirdiğiniz kimlik bilgileriyle çalışır —
> kendi OpenAI uyumlu API anahtarınızla. Hiçbir yapay zekâ hizmeti barındırılmaz
> ya da birlikte gelmez, kota yoktur ve hiçbir istek başkasının sunucularından
> geçmez. Pro, uygulamadaki özelliklerin kilidini açar; yapay zekâ kredisi satın
> almaz. Bkz.
> [Free vs Pro](https://github.com/bostrot/wslmanager/wiki/Pro-Version).

> **Neden ücretli bir katman var?** WSL Manager 2021'den beri tek kişilik, boş
> zamanlarda yürütülen bir proje ve yukarıdaki her özellik — ücretsiz olanlar da
> dahil — akşamlarda ve hafta sonlarında yazıldı. Dağıtımlarınızı ve sanal
> makinelerinizi yönetmek ücretsiz ve öyle kalacak, uygulamanın tamamı da açık
> kaynak kalıyor. Pro, bunun üzerine binen yapay zekâ katmanıdır ve kazandırdığı
> şey, bakımın ve yeni özelliklerin artan zamandan arta kalanla değil, planlı ve
> düzenli bir iş olarak yapılmasını sağlar. Bir kez alın, hep sizde kalsın — ve
> doğrudan bir sonraki sürümü finanse edin.

## 🤖 Yapay zekâ asistanı ve MCP *(Pro)*

Bu bölümdeki her şey **Pro**'nun parçasıdır; ücretsiz uygulamada bunların hiçbiri yoktur.

Yapay zekâ asistanı yalnızca bir sohbet kutusu değil, bir **aracıdır**: MCP
sunucusunun sunduğu araç kümesinin aynısı ona verilir; böylece "hangi dağıtımlarım
var?" diye sorduğunuzda ya da "Ubuntu'yu kur ve varsayılan kullanıcımı ayarla"
dediğinizde, tahmin yürütmek yerine WSL'inize karşı gerçek araçları çağırır. Araç
çağrıları o çalışırken satır arasında gösterilir.

**Sağlayıcıyı ayarlamak** için **Ayarlar → Bring Your Own AI Key** bölümüne gidin:
OpenAI uyumlu her uç nokta çalışır (OpenAI, Azure, bir LiteLLM vekili, Ollama, LM
Studio, …). Temel URL'yi, anahtarı ve modeli girin. **Model listesini yükle**
düğmesi otomatik tamamlamayı sağlayıcının `/models` ucundan doldurur, **Bağlantıyı
test et** ise sohbeti açmadan önce kimlik bilgilerinin çalıştığını kanıtlar.

**Hiçbirini istemiyor musunuz?** **Ayarlar → Bring Your Own AI Key → Yapay zekâ özellikleri** asistanı, hata tanılamayı ve AI Workspace'i kapatır — yapay zekâyla ilgili hiçbir şey gösterilmez ve sizin için çalışma alanı ortamı kurulmaz. Siz yanıtlayana kadar kapalıdır: WSL Manager bunu bir kez sorar, kurulum veya güncelleme sonrası ilk açılışta, ve o ana kadar yapay zekâyla ilgili hiçbir şey çalışmaz.

**Kum havuzları** (AI Workspace → *Kum havuzu dağıtımı ekle*) herhangi bir katalog
imajından (varsayılan olarak en yeni Ubuntu) tek kullanımlık bir örnek oluşturur —
Windows'ta bir WSL dağıtımı, macOS'ta bir bulut imajından türetilen bir Linux sanal
makinesi; her ikisi de sizin için oluşturulup başlatılır. Sohbetine yalnızca o tek
örneğe kilitlenmiş `sandbox_*` araçları verilir — model kum havuzunun *içinde* her
şeyi yapabilir, ama ana makinenizi ya da başka bir örneği asla göremez. Dürüst bir
uyarı: kum havuzunun kendisi, her dağıtım ya da sanal makine gibi, normal biçimde
dışarıya internet erişimine sahiptir. Kum havuzu sohbetleri asistanla aynı sabit
paneli kullanır (görev kuyruğu dahil), dökümleri saklanır ve sohbet başlığındaki
geçmiş düğmesi asistanla herhangi bir kum havuzu oturumu arasında geçiş yapar.

**Görev kuyruğu** — sohbetin üstündeki *Görevler* bölümünü açın, maddeleri ekleyin
ve ▶ tuşuna basın. Asistan araçlarıyla maddeleri sırayla halleder ve bitirdikçe
işaretler; o çalışırken yeni görevler eklemeye devam edebilirsiniz.

### Harici yapay zekâ istemcilerini bağlama (MCP)

**Ayarlar → MCP sunucusu**'nu açın (Pro). MCP protokolünü
`http://127.0.0.1:59133/mcp` adresinde, yalnızca geri döngü arayüzünde ve aynı
panelde gösterilen bir bearer belirteciyle korunarak sunar. Araçlar tüm yaşam
döngüsünü kapsar — dağıtım oluşturma, içe aktarma, yapılandırma, çalıştırma,
paketleme ve (bir onay bayrağıyla) kaydını silme; ayrıca parçacıklar, disk bağlama
ve kalıcı terminal oturumları.

**Claude Desktop** — MCP panelinde **Claude Desktop'ı bağla** düğmesine tıklayın.
Aşağıdaki girdiyi sizin yerinize `claude_desktop_config.json` dosyasına yazar
(Node.js gerekir); ardından Claude Desktop'ı yeniden başlatın. Elle yapmak için ya
da stdio kullanan başka bir MCP istemcisi için HTTP uç noktasını
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) ile köprüleyin:

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

**Claude Code** — aynı köprü, tek komut:

```bash
claude mcp add wsl-manager -- npx -y mcp-remote http://127.0.0.1:59133/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

**opencode** — `opencode.json` dosyanızda (veya `~/.config/opencode/opencode.json` içinde) `mcp` altına ekleyin:

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

Akışlı HTTP konuşan her MCP istemcisi, `mcp-remote`'u atlayarak doğrudan uç noktaya
`Authorization: Bearer <TOKEN>` başlığıyla da bağlanabilir. Başka bir makineden
erişmek için aynı paneldeki yerleşik **Cloudflare tüneli** anahtarını açın ve
yazdırdığı genel URL'yi kullanın.

## 📱 Web panosu *(Pro)*

**Ayarlar → Web panosu**'nu açın (Pro); uygulama ağınızdaki her cihaz için `59134`
bağlantı noktasında bir tarayıcı panosu sunar — Windows'ta da macOS'ta da. Panelin
gösterdiği QR kodu telefonunuzla okutun (ya da bağlantıyı kopyalayın) ve uygulamanın
tamamını tarayıcıda kullanın: örnekleri başlatın, durdurun, çoğaltın ve silin,
komut çalıştırın, kalıcı terminal oturumları açın, kaydettiğiniz parçacıkları
çalıştırın ve diğer bütün araçları (içe aktarma, dışa aktarma, paketleme,
`.wslconfig`, diskler, sanal makine oluşturma) üretilen formlar üzerinden kullanın.
Bu, yapay zekâ asistanının ve MCP sunucusunun kullandığı araç kümesinin aynısıdır.

Erişim, bağlantının parçası olan bir belirteçle korunur (`?token=…`); yani okutulan
bir QR kod, bir cihazın ihtiyaç duyduğu her şeydir — panelde belirteci yeniden
üretmek ise o ana dek dağıtılmış her bağlantıyı iptal eder. Pano bilinçli olarak tüm
arayüzleri dinler; evden uzaktayken geçici bir genel HTTPS bağlantısına ihtiyacınız
olduğunda aynı panelden **Cloudflare tüneliyle yayımla** seçeneğini açın (QR kod da
ona geçer). Yayımlandıktan sonra, komut çalıştırabilen bir yüzeyi koruyan tek şey o
belirteç olur; bu yüzden bağlantıyı dikkatle paylaşın.

## 📦 Kurulum

<details>
<summary>Microsoft Store</summary>

Bu uygulama [Microsoft Store](https://apps.microsoft.com/store/detail/wsl-manager/9NWS9K95NMJB?hl=en-us&gl=US)'da mevcuttur.
</details>

<details>
<summary>Homebrew ile macOS</summary>

```sh
brew install --cask wsl-manager
```

Apple Silicon, macOS 11 veya üzeri. Cask artık Homebrew'ün kendisiyle geliyor, ayrı bir tap gerekmez; `brew upgrade --cask wsl-manager` yeni sürümleri getirir.
</details>

<details>
<summary>Doğrudan indirme</summary>

Bu uygulamayı [Releases](https://github.com/bostrot/wslmanager/releases) sayfasından doğrudan indirebilirsiniz. Windows sürümü kurulum `.exe`'si, `.msix` ve taşınabilir `.zip` olarak; macOS sürümü ise `.dmg` olarak dağıtılır.
</details>

<details>
<summary>Winget ile kurulum</summary>

```sh
winget install Bostrot.WSLManager
```

</details>

<details>
<summary>Scoop ile kurulum</summary>

```sh
scoop install extras/wsl2-distro-manager
```

</details>

<details>
<summary>Chocolatey ile kurulum</summary>

Bu paket topluluk tarafından bakılmaktadır ([@mikeee](https://github.com/mikeee/ChocoPackages)). Resmî bir paket değildir.

```sh
choco install wsl2-distro-manager
```

</details>

<details>
<summary>Gecelik derlemeyi kurma</summary>

En son gecelik derleme, "releaser" iş akışında bir yapı çıktısı olarak ya da [bu bağlantı](https://nightly.link/bostrot/wslmanager/workflows/releaser/main/wsl2-distro-manager-nightly-archive.zip) üzerinden edinilebilir.

</details>

## ⚙️ Derleme

[flutter](https://flutter.dev/desktop)'ın kurulu olduğundan emin olun.

### Windows

```powershell
flutter config --enable-windows-desktop
flutter upgrade

flutter build windows # build it
flutter run -d windows # run it
```

### macOS

Sanal makineleri Flutter uygulamasının kendisi değil, Virtualization.framework'ü
süren küçük bir Swift yardımcısı olan `vmctl` oluşturur. Çerçeve yalnızca
`com.apple.security.virtualization` yetkisini taşıyan süreçlere yanıt verir ve
`swift build` bu yetkiyi eklemez; dolayısıyla **uygulama bir sanal makine
başlatabilmeden önce yardımcının derlenmesi ve imzalanması gerekir**:

```bash
flutter config --enable-macos-desktop

# Build + sign vmctl and install it for dev runs. Re-run after any change
# under macos/vmctl/ — `flutter run` never rebuilds the helper.
VMCTL_ONLY=1 scripts/build_macos.sh

flutter run -d macos
```

Bu adımı atlarsanız uygulama sorunsuz açılır, ama bir sanal makine başlatmak şu
hatayla başarısız olur:

```
VM failed to start: Error Domain=VZErrorDomain Code=2 "The process doesn't
have the "com.apple.security.virtualization" entitlement."
```

Yetkisi eksik olan uygulama değil, *yardımcıdır* — `Runner`'ın kendi yetkileri
zaten doğrudur. İmzalı yardımcı `~/Library/Application
Support/WSLManager/bin/vmctl` yoluna kurulur ve hata ayıklama çalıştırmaları da
oraya bakar; o olmadığında `macos/vmctl/.build/` altındaki imzasız `swift build`
çıktısına düşerler ki yukarıdaki hatayı üreten de budur.

`scripts/build_macos.sh`, `VMCTL_ONLY` olmadan aynı imzalamayı yapar ve ardından
sürüm uygulamasını derleyip imzalı yardımcıyı paketin `Contents/Resources/` klasörüne
koyar. Uygulamanın kendisini derlemek için tam Xcode gerekir.

## Yazar

👤 **Eric Trenkel**

- Web sitesi: [erictrenkel.com](https://erictrenkel.com)
- GitHub: [@bostrot](https://github.com/bostrot)
- LinkedIn: [@erictrenkel](https://linkedin.com/in/erictrenkel)

👥 **Katkıda bulunanlar**

[![Contributors](https://contrib.rocks/image?repo=bostrot/wslmanager)](https://github.com/bostrot/wslmanager/graphs/contributors)

## 🤝 Katkıda bulunma

Katkılar, sorun bildirimleri ve özellik istekleri memnuniyetle karşılanır!\
[Sorunlar sayfasına](https://github.com/bostrot/wslmanager/issues) göz atabilirsiniz.
Ayrıca [katkı rehberine](https://github.com/bostrot/wslmanager/blob/main/CONTRIBUTING.md) da bakabilirsiniz.

## Desteğinizi gösterin

Bu proje size yardımcı olduysa bir ⭐️ verin!

## 📝 Lisans

Telif hakkı © 2026 [Eric Trenkel](https://github.com/bostrot).\
Bu proje [GPL-3.0](https://github.com/bostrot/wslmanager/blob/main/LICENSE) ile lisanslanmıştır.

---

_Aradığınızı bulamadınız mı? [Wiki](https://github.com/bostrot/wslmanager/wiki)'ye göz atın_
