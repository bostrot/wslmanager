<h1 align="center">Üdvözlünk a WSL Managerben 👋</h1>

![GitHub Release Date](https://img.shields.io/github/release-date/bostrot/wslmanager?style=for-the-badge)
![GitHub Workflow](https://img.shields.io/github/actions/workflow/status/bostrot/wslmanager/releaser.yml?branch=main&label=nightly&style=for-the-badge)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/bostrot/wslmanager?style=for-the-badge)
[![Documentation](https://img.shields.io/badge/DOCUMENTATION-WIKI-green?style=for-the-badge)](https://github.com/bostrot/wslmanager/wiki)
[![GitLab stars](https://img.shields.io/gitlab/stars/bostrot/wsl2-distro-manager?gitlab_url=https%3A%2F%2Fgitlab.com&label=GitLab&style=for-the-badge)](https://gitlab.com/bostrot/wsl2-distro-manager)
[![Discord](https://img.shields.io/discord/1100070299308937287?style=for-the-badge)](https://discord.gg/fY5uE5WRTP)


<p align='center'>
    <a href='../README.md'>English</a> | <a href='./README_zh.md'>简体中文</a> | <a href='./README_zh_tw.md'>繁體中文</a> | <a href='./README_de.md'>Deutsch</a> | <a href='./README_es.md'>Español</a> | <a href='./README_ja.md'>日本語</a> | Magyar | <a href='./README_pt.md'>Português</a> | <a href='./README_tr.md'>Türkçe</a>
</p>

![WSL Distro Manager Windowson, sötét téma](./images/home-dark.png)

<p align='center'>
    <sub><b>Windowson</b> mutatva &middot; ugyanez az alkalmazás natív virtuális gépeket kezel <b>macOS</b> alatt &mdash; nyisd ki lentebb a <b>Nézd meg macOS-en</b> részt</sub>
</p>

<details>
<summary>Előnézet világos témával (Windows)</summary>

![WSL Distro Manager Windowson, világos téma](./images/home-light.png)

</details>

<details>
<summary><b>🍎 Nézd meg macOS-en</b> &mdash; natív Linux és macOS virtuális gépek az Apple Virtualization keretrendszerén keresztül <i>(béta)</i></summary>

![WSL Manager macOS-en, sötét téma](./images/home-macos-dark.png)

![WSL Manager macOS-en, világos téma, megnyitott MI-asszisztenssel](./images/home-macos-light.png)

</details>

> A **WSL Distro Manager** egy ingyenes, nyílt forráskódú grafikus felület a
> Windows Subsystem for Linuxhoz — macOS-en pedig natív Linux virtuális gépekhez.
> Telepíts, másolj, nevezz át, helyezz át, ments és törölj WSL-disztribúciókat
> anélkül, hogy egyetlen `wsl.exe` kapcsolót is meg kellene jegyezned — mindezt
> sablonokkal, elmentett parancsrészletekkel, lemezcsatolással, `.wslconfig`
> szerkesztéssel, SSH-n keresztüli távoli WSL-lel és egy MCP-kiszolgálóval együtt,
> amellyel MI-ügynökök is vezérelhetik a WSL-környezetedet. Mac gépen ugyanez az
> alkalmazás az Apple Virtualization keretrendszerén át kezel virtuális gépeket.

## 🚀 Funkciók

**Disztribúciók kezelése**
- [x] Telepítés beépített katalógusból, vagy hozd a saját rootfs-edet
- [x] Példányok másolása, átnevezése, másik meghajtóra helyezése, mentése és törlése
- [x] Minden példány mentése egy mappába – a tartalom listájával együtt –, majd visszaállítás egy másik gépen
- [x] Virtuális lemezek tömörítése, hogy visszakapd a helyet, amit a WSL sosem ad vissza
- [x] Nézd meg, mit használ épp egy példány – processzor, memória és swap, élő grafikonnal
- [x] Támogatja az Ubuntut, Debiant, Alpine-t, Kali Linuxot, openSUSE-t, SLES-t és mindent, amit a WSL elfogad

**Gyorsabban működő példányok**
- [x] Bármely Docker-képfájl használható disztribúcióként — magához a Dockerhez nincs szükség
- [x] Csomagolj egy beállított disztribúciót hordozható `.wsl` fájlba, amely bármely gépen telepíthető (a sablonokat ez váltja fel)
- [x] Turnkey Linux és más LXC-konténerek (kísérleti)
- [x] Parancsrészletek: tartsd a telepítőparancsaidat az alkalmazásban, és futtasd őket bármely példányon
- [x] Irányítsd az alkalmazást a saját rootfs-képfájl tárolódra
- [x] Böngészd egy disztró fájljait, és másold a kiválasztottakat egy másik példányba — megosztás, csatolás és Fájlkezelő nélkül

<!-- Unreleased. Containers, Kubernetes and Cloud are built but ship only in
     debug runs (LicenseManager.unreleasedFeaturesVisible, the gate Pro rides
     in a debug build); a release has none of them, so the README must not
     promise them. Lift the comment together with the gate.

**Docker- és Podman-konténerek**
- [x] Lásd a gép összes konténerét — mindkét motort egyszerre — a példányaid mellett
- [x] Indítsd, állítsd le, indítsd újra, távolítsd el a konténereket és kövesd a naplóikat anélkül, hogy elhagynád az alkalmazást
- [x] Csak felület: a már meglévő `docker`/`podman` parancsodat vezérli, és semmit nem telepít
- [x] Az MI-csevegés és az MCP-kiszolgáló ugyanazokat a konténereszközöket kapja

**Kubernetes-fürtök**
- [x] A kubeconfigod minden fürtje, egyszerre egy névtér — tíz fürtre és száz alkalmazásra tervezve
- [x] Deploymentek, StatefulSetek és DaemonSetek állapota egy pillantásra, névre, névtérre vagy képfájlra szűrve
- [x] Nyiss meg egy munkaterhelést, hogy lásd a podjait, kövesd a naplóikat, újraindíts egy podot, indíts gördülő újraindítást, skálázz vagy elolvasd a teljes részleteket
- [x] Csak felület: a már meglévő `kubectl` parancsodat vezérli, sosem írja át a kubeconfigodat és nem vált kontextust
- [x] Az MI-csevegés és az MCP-kiszolgáló is olvassa a fürtjeidet — munkaterhelések, podok, események, erőforrás-használat és kereshető pod-naplók —, de csak olvassa: semmi sem indíthat újra, méretezhet át vagy törölhet

**Telepítés a felhőbe** *(béta)*
- [x] Told fel egy teljes példányt egy vadonatúj Hetzner Cloud kiszolgálóra egyetlen lépésben — a gyökérfájlrendszer exportálódik, feltöltődik és konténerként indul el ott
- [x] A kiszolgálót az alkalmazás hozza létre: méret, hely és alapképfájl, a cloud-init pedig telepíti a Dockert és engedélyezi a saját SSH-kulcsodat a `root` felhasználóhoz
- [x] macOS-ről is működik: egy Linux virtuális gép gyökérfájlrendszerét a futó vendégből olvassa ki, mert annak lemezképe egy indítható gép, nem pedig valami, amit egy konténermotor el tudna olvasni
- [x] Bármikor visszahúzhatod új helyi példányként, miközben a kiszolgáló tovább fut — macOS-en annak a virtuális gépnek a másolatába áll vissza, amelyikből telepítve lett, és ennek még léteznie kell és leállított állapotban kell lennie, mert egy csupasz gyökérfájlrendszernek nincs kernelje, amivel elindulhatna
- [x] Lásd, mennyibe kerül havonta az egyes kiszolgálók, kapcsold be és ki őket, és töröld is őket ugyanabból a listából
-->

**Beállítás fájlok kézi szerkesztése nélkül**
- [x] systemd, automount, alapértelmezett felhasználó, indítóparancs és indítási útvonal disztribúciónként
- [x] Memória, processzorok, swap, hálózati mód, DNS és a `.wslconfig` többi része
- [x] Csatolj fizikai lemezt vagy VHD-t a WSL-be, partíció- és fájlrendszer-választással
- [x] Gazdagép-mappák megosztása egy disztróba vagy VM-be tetszőleges csatolási ponton, akár csak olvashatóan — az AI Workspace számára is

**Dolgozz úgy, ahogy megszoktad**
- [x] Nyisd meg a Windows Terminált, a VS Code-ot vagy az Intézőt közvetlenül egy disztribúción belül
- [x] Minden példány ott a Windows Terminal menüjében, naprakészen, amíg az alkalmazás fut — saját fragmentként kerül oda, így a Terminal beállításaihoz soha nem nyúlunk
- [x] Kezeld a WSL-t egy *másik* Windows gépen SSH-n keresztül
- [x] Szinkronizálj egy disztribúciót a hálózatod két gépe között
- [x] Érd el a példányokat a nevükkel: a hosztnevük a hosts fájlban marad naprakész, így az `ssh ubuntu.wsl` újraindítás után is működik
- [x] Naprakészen tartja magát: a weboldalról és a GitHubról származó változatok maguk töltik le és telepítik az új kiadásokat (a Store-ból telepítetteket a Store frissíti)
- [x] Sötét és világos téma, kilenc nyelven elérhető

**macOS-en: natív virtuális gépek** *(béta)*
- [x] Ugyanez az alkalmazás a WSL helyett az Apple Virtualization keretrendszerével kezel virtuális gépeket
- [x] Hozz létre Linux virtuális gépeket telepítő ISO-ból, felhőképfájlból vagy exportált sablonból
- [x] Hozz létre macOS vendéggépeket helyreállítási képfájlból (Apple Silicon)
- [x] Indítsd, állítsd le, klónozd, exportáld/importáld és sablonozd a virtuális gépeket, akárcsak a disztribúciókat
- [x] Futtass parancsokat a virtuális gépeken belül automatikusan beállított SSH-n (cloud-init) keresztül, a grafikus felületről, az MI-csevegésből vagy MCP-kliensekből
- [x] Terminál bármelyik virtuális géphez a saját sorából: SSH-munkamenet a Linux vagy macOS vendégben, illetve a soros konzol, ha egy Linux vendégen nincs mihez csatlakozni
- [x] A saját `~/.ssh` kulcsod minden Linux virtuális gépben engedélyezve lesz (és létrejön, ha nincs), így a sima `ssh felhasznalo@vm-ip` is működik
- [x] Minden virtuális gép kap egy bejelentkezési jelszót, amelyet a sorából olvashatsz vissza, hogy a gép saját képernyőjén is be tudj lépni
- [x] Ugyanabban a sorban beállíthatod, melyik fiókkal lép be minden SSH-útvonal — a macOS vendég nevét a beállítóasszisztensbe írod, ahol az alkalmazás nem látja
- [x] Fordítás a `scripts/build_macos.sh` paranccsal — becsomagolja az aláírt `vmctl` segédprogramot

**Pro** *(egyszeri vásárlás: Microsoft Store Windowson, licenckulcs a [wslmanager.com/buy](https://wslmanager.com/buy/) oldalról macOS-en és a Store-on kívüli telepítésekhez — sosem előfizetés)*
- [x] **AI Workspace** — futtasd a Hermes Agentet, az OpenClaw-t, az Open WebUI-t és az OpenCode-ot egy külön, elszigetelt WSL-disztribúcióban
- [x] **Egy modell és végpont minden AI-eszközhöz** — az asszisztens Beállításokban megadott API-végpontját, kulcsát és modelljét használja az OpenCode, az OpenClaw és a Hermes is; add meg egyszer, és a később telepített eszköz is megkapja
- [x] **MI-asszisztens eszközökkel** — a beépített csevegés valóban *működtetni* tudja a WSL-edet: kilistázza és megvizsgálja a disztribúciókat, parancsokat futtat, beállításokat szerkeszt, parancsrészleteket hoz létre, lemezeket csatol és disztribúciókat csomagol ugyanazokkal az eszközökkel, amelyeket az MCP-kiszolgáló is kínál
- [x] **Minden példányt módosító MI-futtatás parancsrészletként lesz elmentve** — a lefuttatott parancsokkal és azzal, amit az egyes eszközök jelentettek, a csevegésből hivatkozva, hogy átnézhesd, egy friss példányon újra lefuttathasd vagy megoszthasd
- [x] **Homokozóba zárt MI** — indíts egy eldobható Ubuntu disztribúciót, és adj egy MI-csevegésnek hozzáférést *kizárólag* annak a homokozónak a belsejéhez
- [x] **Feladatsor** — adj az asszisztensnek egy listát, és hagyd, hogy végigdolgozza, közben kipipálva a tételeket
- [x] **MCP-kiszolgáló** — tedd elérhetővé a WSL-t a Claude Desktop, a Claude Code, az opencode és más MCP-kliensek számára
- [x] **Webes vezérlőpult** — kezelj mindent a telefonodról vagy egy másik gépről: olvass be egy QR-kódot, és megkapod a teljes alkalmazást a böngészőben, igény szerint a hálózatodon kívülre is közzétéve egy Cloudflare-alagúton át

> Az MI-funkciók az **általad** hozott hitelesítő adatokkal működnek — a saját,
> OpenAI-kompatibilis API-kulcsoddal. Semmilyen MI-szolgáltatás nincs üzemeltetve
> vagy mellékelve, nincs kvóta, és egyetlen kérés sem halad át más kiszolgálóján.
> A Pro az alkalmazás funkcióit oldja fel; nem MI-kreditet vásárolsz vele. Lásd:
> [Free vs Pro](https://github.com/bostrot/wslmanager/wiki/Pro-Version).

> **Miért van egyáltalán fizetős csomag?** A WSL Manager 2021 óta egyszemélyes,
> szabadidőben készülő projekt, és a fenti összes funkció — az ingyenesek is —
> esténként és hétvégenként született. A disztribúcióid és virtuális gépeid
> kezelése ingyenes, és az is marad, az egész alkalmazás pedig nyílt forráskódú
> marad. A Pro az erre épülő MI-réteg, és amit hoz, az teszi lehetővé, hogy a
> karbantartás és az új funkciók tervezett, rendszeres munkává váljanak ahelyett,
> hogy csak a maradék időből jutna rájuk. Vedd meg egyszer, tartsd meg örökre —
> és közvetlenül a következő kiadást finanszírozod vele.

## 🤖 MI-asszisztens és MCP *(Pro)*

Minden, ami ebben a szakaszban szerepel, a **Pro** része; az ingyenes alkalmazásban egyik sincs benne.

Az MI-asszisztens **ügynök**, nem pusztán egy csevegőablak: ugyanazt az
eszközkészletet kapja meg, amelyet az MCP-kiszolgáló kínál, így amikor azt kérdezed,
hogy „milyen disztribúcióim vannak?”, vagy azt mondod, „telepítsd az Ubuntut és
állítsd be az alapértelmezett felhasználómat”, valódi eszközöket hív meg a WSL-eden
találgatás helyett. Az eszközhívások munka közben, a beszélgetésben jelennek meg.

**Állítsd be a szolgáltatót** a **Beállítások → Bring Your Own AI Key** részben:
bármely OpenAI-kompatibilis végpont működik (OpenAI, Azure, egy LiteLLM-proxy,
Ollama, LM Studio, …). Add meg az alap-URL-t, a kulcsot és a modellt. A **Modellek
listájának betöltése** gomb a szolgáltató `/models` végpontjából tölti fel az
automatikus kiegészítést, a **Kapcsolat tesztelése** pedig bizonyítja, hogy a
hitelesítő adatok működnek, még mielőtt megnyitnád a csevegést.

**Egyik sem kell?** A **Beállítások → Bring Your Own AI Key → MI-funkciók** kapcsoló kikapcsolja az asszisztenst, a hibadiagnosztikát és az AI Workspace-t — semmi MI-vel kapcsolatos nem jelenik meg, és nem készül el helyetted a munkaterület-környezet sem. Addig ki van kapcsolva, amíg nem válaszolsz: a WSL Manager egyszer kérdez rá, a telepítés vagy frissítés utáni első indításkor, és addig semmi MI-vel kapcsolatos nem fut.

**Homokozók** (AI Workspace → *Homokozó disztribúció hozzáadása*) eldobható példányt
hoznak létre bármely katalógusképfájlból (alapértelmezés szerint a legújabb Ubuntuból)
— Windowson WSL-disztribúciót, macOS-en felhőképfájlból induló Linux virtuális gépet,
amelyet létrehozunk és el is indítunk helyetted. A csevegése csak a `sandbox_*`
eszközöket kapja meg, amelyek arra az egyetlen példányra vannak zárva — a modell
bármit megtehet a homokozó *belsejében*, de sosem látja a gazdagépedet vagy bármely
más példányt. Egy őszinte kikötés: maga a homokozó a szokásos módon kifelé elérheti
az internetet, mint bármely disztribúció vagy virtuális gép. A homokozós csevegések
ugyanazt a dokkolt panelt használják, mint az asszisztens (a feladatsorral együtt),
az átirataik megmaradnak, a csevegés fejlécében lévő előzménygomb pedig az asszisztens
és bármelyik homokozós munkamenet között vált.

**Feladatsor** — nyisd meg a *Feladatok* szakaszt a csevegés tetején, vedd fel a
tételeket, és nyomd meg a ▶ gombot. Az asszisztens az eszközeivel végigmegy rajtuk, és
mindegyiket kipipálja, ahogy elkészül; közben újabb feladatokat is felvehetsz.

### Külső MI-kliensek csatlakoztatása (MCP)

Kapcsold be a **Beállítások → MCP-kiszolgáló** funkciót (Pro). Az MCP protokollt a
`http://127.0.0.1:59133/mcp` címen szolgálja ki, kizárólag a visszacsatolási felületen,
és egy bearer tokennel védve, amelyet ugyanaz a panel mutat. Az eszközök a teljes
életciklust lefedik — disztribúciók létrehozása, importálása, beállítása, futtatása,
csomagolása és (megerősítő kapcsolóval) leválasztása, továbbá parancsrészletek,
lemezcsatolás és tartós terminál-munkamenetek.

**Claude Desktop** — kattints a **Claude Desktop csatlakoztatása** gombra az MCP
panelen. Helyetted írja be az alábbi bejegyzést a `claude_desktop_config.json` fájlba
(Node.js szükséges hozzá); utána indítsd újra a Claude Desktopot. Kézzel, vagy bármely
más stdio MCP-klienshez, hidald át a HTTP-végpontot az
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) segítségével:

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

**Claude Code** — ugyanaz a híd, egyetlen paranccsal:

```bash
claude mcp add wsl-manager -- npx -y mcp-remote http://127.0.0.1:59133/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

**opencode** — vedd fel az `mcp` alá az `opencode.json` fájlodban (vagy a `~/.config/opencode/opencode.json` fájlban):

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

Bármely MCP-kliens, amely beszéli a folyamatos HTTP-t, közvetlenül is a végpontra
mutathat egy `Authorization: Bearer <TOKEN>` fejléccel, kihagyva az `mcp-remote`-ot.
Ha másik gépről szeretnéd elérni, kapcsold be a beépített **Cloudflare-alagút**
kapcsolót ugyanazon a panelen, és használd a kiírt nyilvános URL-t.

## 📱 Webes vezérlőpult *(Pro)*

Kapcsold be a **Beállítások → Webes vezérlőpult** funkciót (Pro), és az alkalmazás az
`59134` porton böngészős vezérlőpultot szolgál ki a hálózatod minden eszközének —
Windowson és macOS-en egyaránt. Olvasd be a panelen megjelenő QR-kódot a telefonoddal
(vagy másold ki a hivatkozást), és megkapod a teljes alkalmazást a böngészőben:
példányok indítása, leállítása, másolása és törlése, parancsok futtatása, tartós
terminál-munkamenetek megnyitása, az elmentett parancsrészleteid futtatása, és minden
más eszköz (importálás, exportálás, csomagolás, `.wslconfig`, lemezek, virtuálisgép-
létrehozás) használata generált űrlapokon keresztül. Ugyanaz az eszközkészlet, amelyet
az MI-asszisztens és az MCP-kiszolgáló is használ.

A hozzáférést egy token védi, amely a hivatkozás része (`?token=…`), így egy beolvasott
QR-kód minden, amire egy eszköznek szüksége van — a token újragenerálása a panelen
pedig visszavonja az összes eddig kiadott hivatkozást. A vezérlőpult szándékosan minden
hálózati felületen figyel; kapcsold át a **Közzététel Cloudflare-alagúton** lehetőséget
ugyanitt, ha ideiglenes nyilvános HTTPS-hivatkozásra van szükséged (a QR-kód is arra vált),
amikor nem vagy otthon. Közzététel után a token az egyetlen, ami egy parancsfuttatásra
képes felületet véd, ezért óvatosan oszd meg azt a hivatkozást.

## 📦 Telepítés

<details>
<summary>Microsoft Store</summary>

Ez az alkalmazás elérhető a [Microsoft Store](https://apps.microsoft.com/store/detail/wsl-manager/9NWS9K95NMJB?hl=en-us&gl=US)-ban.
</details>

<details>
<summary>macOS Homebrew-val</summary>

```sh
brew install --cask wsl-manager
```

Apple Silicon, macOS 11 vagy újabb. A cask magában a Homebrew-ban található, így nincs szükség tapre; a `brew upgrade --cask wsl-manager` hozza az új kiadásokat.
</details>

<details>
<summary>Közvetlen letöltés</summary>

Az alkalmazást közvetlenül is letöltheted a [Releases](https://github.com/bostrot/wslmanager/releases) oldalról. A Windows-változat telepítő `.exe`, `.msix` és hordozható `.zip` formában érkezik; a macOS-változat `.dmg`-ként.
</details>

<details>
<summary>Telepítés Winget segítségével</summary>

```sh
winget install Bostrot.WSLManager
```

</details>

<details>
<summary>Telepítés Scoop segítségével</summary>

```sh
scoop install extras/wsl2-distro-manager
```

</details>

<details>
<summary>Telepítés Chocolatey segítségével</summary>

Ezt a csomagot a közösség tartja karban ([@mikeee](https://github.com/mikeee/ChocoPackages)). Nem hivatalos csomag.

```sh
choco install wsl2-distro-manager
```

</details>

<details>
<summary>Éjszakai build telepítése</summary>

A legfrissebb éjszakai build a „releaser” munkafolyamat termékeként, vagy [ezen a hivatkozáson](https://nightly.link/bostrot/wslmanager/workflows/releaser/main/wsl2-distro-manager-nightly-archive.zip) keresztül érhető el.

</details>

## ⚙️ Fordítás

Győződj meg róla, hogy a [flutter](https://flutter.dev/desktop) telepítve van.

### Windows

```powershell
flutter config --enable-windows-desktop
flutter upgrade

flutter build windows # build it
flutter run -d windows # run it
```

### macOS

A virtuális gépeket a `vmctl` hozza létre, egy apró Swift segédprogram, amely a
Virtualization.frameworköt vezérli — nem maga a Flutter alkalmazás. A keretrendszer
csak olyan folyamatoknak válaszol, amelyek rendelkeznek a
`com.apple.security.virtualization` jogosultsággal, a `swift build` pedig nem adja
hozzá, ezért **a segédprogramot le kell fordítani és alá kell írni, mielőtt az
alkalmazás elindíthatna egy virtuális gépet**:

```bash
flutter config --enable-macos-desktop

# Build + sign vmctl and install it for dev runs. Re-run after any change
# under macos/vmctl/ — `flutter run` never rebuilds the helper.
VMCTL_ONLY=1 scripts/build_macos.sh

flutter run -d macos
```

Ha kihagyod ezt a lépést, az alkalmazás elindul, de a virtuális gép indítása ezzel
bukik el:

```
VM failed to start: Error Domain=VZErrorDomain Code=2 "The process doesn't
have the "com.apple.security.virtualization" entitlement."
```

Ez a *segédprogramból* hiányzó jogosultság, nem az alkalmazásból — a `Runner` saját
jogosultságai már rendben vannak. Az aláírt segédprogram a
`~/Library/Application Support/WSLManager/bin/vmctl` helyre kerül, és a hibakeresési
futtatások is ott keresik; nélküle a `macos/vmctl/.build/` alatti aláíratlan
`swift build` kimenetre esnek vissza, ami pontosan a fenti hibát okozza.

A `scripts/build_macos.sh` `VMCTL_ONLY` nélkül ugyanezt az aláírást végzi el, majd
lefordítja a kiadási alkalmazást, és az aláírt segédprogramot a csomag
`Contents/Resources/` könyvtárába teszi. Magának az alkalmazásnak a fordításához a
teljes Xcode szükséges.

## Szerző

👤 **Eric Trenkel**

- Weboldal: [erictrenkel.com](https://erictrenkel.com)
- GitHub: [@bostrot](https://github.com/bostrot)
- LinkedIn: [@erictrenkel](https://linkedin.com/in/erictrenkel)

👥 **Közreműködők**

[![Contributors](https://contrib.rocks/image?repo=bostrot/wslmanager)](https://github.com/bostrot/wslmanager/graphs/contributors)

## 🤝 Hozzájárulás

A hozzájárulásokat, hibajelentéseket és funkciókéréseket szívesen fogadjuk!\
Nézd meg az [issues oldalt](https://github.com/bostrot/wslmanager/issues).
Érdemes belenézni a [hozzájárulási útmutatóba](https://github.com/bostrot/wslmanager/blob/main/CONTRIBUTING.md) is.

## Támogasd a projektet

Adj egy ⭐️-ot, ha ez a projekt segített neked!

## 📝 Licenc

Copyright © 2026 [Eric Trenkel](https://github.com/bostrot).\
Ez a projekt [GPL-3.0](https://github.com/bostrot/wslmanager/blob/main/LICENSE) licenc alatt áll.

---

_Nem találtad, amit kerestél? Nézz körül a [Wikiben](https://github.com/bostrot/wslmanager/wiki)_
