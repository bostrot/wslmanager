<h1 align="center">Willkommen bei WSL Manager 👋</h1>

![GitHub Release Date](https://img.shields.io/github/release-date/bostrot/wslmanager?style=for-the-badge)
![GitHub Workflow](https://img.shields.io/github/actions/workflow/status/bostrot/wslmanager/releaser.yml?branch=main&label=nightly&style=for-the-badge)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/bostrot/wslmanager?style=for-the-badge)
[![Documentation](https://img.shields.io/badge/DOCUMENTATION-WIKI-green?style=for-the-badge)](https://github.com/bostrot/wslmanager/wiki)
[![GitLab stars](https://img.shields.io/gitlab/stars/bostrot/wsl2-distro-manager?gitlab_url=https%3A%2F%2Fgitlab.com&label=GitLab&style=for-the-badge)](https://gitlab.com/bostrot/wsl2-distro-manager)
[![Discord](https://img.shields.io/discord/1100070299308937287?style=for-the-badge)](https://discord.gg/fY5uE5WRTP)


<p align='center'>
    <a href='../README.md'>English</a> | <a href='./README_zh.md'>简体中文</a> | <a href='./README_zh_tw.md'>繁體中文</a> | Deutsch | <a href='./README_es.md'>Español</a> | <a href='./README_ja.md'>日本語</a> | <a href='./README_hu.md'>Magyar</a> | <a href='./README_pt.md'>Português</a> | <a href='./README_tr.md'>Türkçe</a>
</p>

![WSL Distro Manager unter Windows, dunkles Design](./images/home-dark.png)

<p align='center'>
    <sub>Gezeigt unter <b>Windows</b> &middot; dieselbe App verwaltet native VMs unter <b>macOS</b> &mdash; siehe <b>Unter macOS ansehen</b> weiter unten</sub>
</p>

<details>
<summary>Vorschau mit hellem Design (Windows)</summary>

![WSL Distro Manager unter Windows, helles Design](./images/home-light.png)

</details>

<details>
<summary><b>🍎 Unter macOS ansehen</b> &mdash; native Linux- und macOS-VMs über Apples Virtualization-Framework <i>(Beta)</i></summary>

![WSL Manager unter macOS, dunkles Design](./images/home-macos-dark.png)

![WSL Manager unter macOS, helles Design, mit geöffnetem KI-Assistenten](./images/home-macos-light.png)

</details>

> **WSL Distro Manager** ist eine kostenlose, quelloffene grafische Oberfläche
> für das Windows Subsystem für Linux — und unter macOS für native Linux-VMs.
> Installieren, kopieren, umbenennen, verschieben, sichern und löschen Sie
> WSL-Distributionen, ohne sich eine einzige `wsl.exe`-Option merken zu müssen
> — dazu Vorlagen, gespeicherte Befehls-Snippets, das Einbinden von
> Datenträgern, das Bearbeiten von `.wslconfig`, WSL per SSH aus der Ferne und
> ein MCP-Server, über den KI-Agenten Ihre WSL-Umgebung steuern können. Auf
> einem Mac verwaltet genau dieselbe App stattdessen virtuelle Maschinen über
> Apples Virtualization-Framework.

## 🚀 Funktionen

**Distributionen verwalten**
- [x] Installation aus einem eingebauten Katalog oder mit Ihrem eigenen rootfs
- [x] Instanzen kopieren, umbenennen, auf ein anderes Laufwerk verschieben, sichern und löschen
- [x] Alle Instanzen in einen Ordner sichern – samt Liste, was darin liegt – und auf einem anderen PC wiederherstellen
- [x] Virtuelle Datenträger komprimieren und Platz zurückholen, den WSL nie wieder freigibt
- [x] Sehen, was eine Instanz gerade verbraucht – Rechenzeit, Arbeitsspeicher und Swap, mit laufendem Diagramm
- [x] Unterstützt Ubuntu, Debian, Alpine, Kali Linux, openSUSE, SLES und alles andere, was WSL akzeptiert

**Instanzen schneller startklar bekommen**
- [x] Jedes Docker-Image als Distribution nutzen — Docker selbst wird nicht benötigt
- [x] Eine eingerichtete Distribution als portable `.wsl`-Datei verpacken, die sich auf jedem Rechner installieren lässt (Vorlagen sind zugunsten dieser Dateien veraltet)
- [x] Turnkey Linux und andere LXC-Container (experimentell)
- [x] Snippets: Ihre Einrichtungsbefehle in der App behalten und auf jeder Instanz ausführen
- [x] Die App auf Ihr eigenes Repository mit rootfs-Images zeigen lassen
- [x] Die Dateien einer Distro durchsehen und die ausgewählten in eine andere Instanz kopieren — ohne Freigabe, ohne Mount, ohne Explorer

<!-- Unreleased. Containers, Kubernetes and Cloud are built but ship only in
     debug runs (LicenseManager.unreleasedFeaturesVisible, the gate Pro rides
     in a debug build); a release has none of them, so the README must not
     promise them. Lift the comment together with the gate.

**Docker- und Podman-Container**
- [x] Jeder Container auf dem Rechner — beide Engines zugleich — direkt neben Ihren Instanzen
- [x] Container starten, stoppen, neu starten, entfernen und ihre Logs verfolgen, ohne die App zu verlassen
- [x] Nur eine Oberfläche: sie steuert das vorhandene `docker`/`podman` und installiert nichts
- [x] Der KI-Chat und der MCP-Server bekommen dieselben Container-Werkzeuge

**Kubernetes-Cluster**
- [x] Jeder Cluster Ihrer kubeconfig, ein Namespace nach dem anderen — gebaut für zehn Cluster mit hundert Anwendungen
- [x] Deployments, StatefulSets und DaemonSets mit Zustand auf einen Blick, gefiltert nach Name, Namespace oder Image
- [x] Ein Workload öffnen, seine Pods sehen, deren Logs verfolgen, einen Pod neu starten, einen Rollout-Restart auslösen, skalieren oder die vollen Details lesen
- [x] Nur eine Oberfläche: sie steuert das vorhandene `kubectl`, schreibt Ihre kubeconfig nie um und wechselt nie Ihren Kontext
- [x] Auch der KI-Chat und der MCP-Server lesen Ihre Cluster — Workloads, Pods, Ereignisse, Ressourcenverbrauch und durchsuchbare Pod-Logs — und lesen sie nur: nichts davon kann etwas neu starten, skalieren oder löschen

**In die Cloud ausrollen** *(Beta)*
- [x] Eine ganze Instanz in einem Schritt auf einen brandneuen Hetzner-Cloud-Server bringen — das Root-Dateisystem wird exportiert, hochgeladen und dort als Container gestartet
- [x] Der Server wird für Sie angelegt: Größe, Standort und Basis-Image, mit cloud-init, das Docker installiert und Ihren eigenen SSH-Schlüssel für `root` autorisiert
- [x] Funktioniert auch von macOS aus: das Root-Dateisystem einer Linux-VM wird aus dem laufenden Gast gelesen, denn ihr Datenträger-Image ist eine startfähige Maschine und nichts, was eine Container-Engine lesen könnte
- [x] Holen Sie sie jederzeit als neue lokale Instanz zurück, während der Server weiterläuft — unter macOS wird dabei in eine Kopie der VM zurückgespielt, aus der sie ausgerollt wurde; diese muss noch existieren und gestoppt sein, weil ein bloßes Root-Dateisystem keinen Kernel zum Starten hat
- [x] Sehen Sie, was jeder Server pro Monat kostet, schalten Sie sie ein und aus und löschen Sie sie aus derselben Liste
-->

**Konfigurieren, ohne Dateien von Hand zu bearbeiten**
- [x] systemd, automount, Standardbenutzer, Startbefehl und Startpfad je Distribution
- [x] Arbeitsspeicher, Prozessoren, Swap, Netzwerkmodus, DNS und der Rest von `.wslconfig`
- [x] Einen physischen Datenträger oder eine VHD in WSL einbinden, mit Kontrolle über Partition und Dateisystem
- [x] Host-Ordner unter einem frei gewählten Einhängepunkt in eine Distro oder VM freigeben, auf Wunsch schreibgeschützt — auch für den AI Workspace

**So arbeiten, wie Sie es ohnehin tun**
- [x] Windows Terminal, VS Code oder den Explorer direkt in einer Distribution öffnen
- [x] Jede Instanz im Windows-Terminal-Menü, aktuell gehalten, solange die App läuft — als eigenes Fragment beigesteuert, sodass Ihre Terminal-Einstellungen nie verändert werden
- [x] WSL auf einem *anderen* Windows-Rechner per SSH verwalten
- [x] Eine Distribution zwischen zwei Rechnern im Netzwerk abgleichen
- [x] Instanzen über ihren Namen erreichen: der Hostname wird in der hosts-Datei gepflegt, `ssh ubuntu.wsl` funktioniert also auch nach einem Neustart
- [x] Hält sich selbst aktuell: die Website- und GitHub-Builds laden neue Versionen selbst herunter und installieren sie (Store-Installationen werden vom Store aktualisiert)
- [x] Dunkles und helles Design, verfügbar in neun Sprachen

**Unter macOS: native virtuelle Maschinen** *(Beta)*
- [x] Dieselbe App verwaltet VMs über Apples Virtualization-Framework statt über WSL
- [x] Linux-VMs aus einer Installations-ISO, einem Cloud-Image oder einer exportierten Vorlage erstellen
- [x] macOS-Gast-VMs aus einem Restore-Image erstellen (Apple Silicon)
- [x] VMs wie Distributionen starten, stoppen, klonen, exportieren/importieren und als Vorlage sichern
- [x] Befehle in VMs über automatisch eingerichtetes SSH (cloud-init) ausführen — aus der Oberfläche, dem KI-Chat oder von MCP-Clients
- [x] Ein Terminal zu jeder VM direkt aus ihrer Zeile: eine SSH-Sitzung im Linux- oder macOS-Gast, die serielle Konsole, wenn es bei Linux nichts zum Verbinden gibt
- [x] Ihr eigener `~/.ssh`-Schlüssel wird in jeder Linux-VM autorisiert (und angelegt, falls Sie keinen haben), sodass auch schlicht `ssh user@vm-ip` funktioniert
- [x] Jede VM bekommt ein Anmeldekennwort, das Sie in ihrer Zeile nachlesen können, um sich am Bildschirm der VM selbst anzumelden
- [x] Das Konto, mit dem sich jeder SSH-Weg anmeldet, lässt sich in derselben Zeile festlegen — der Name eines macOS-Gasts wird im Systemassistenten eingegeben, wo die App ihn nicht sieht
- [x] Bauen mit `scripts/build_macos.sh` — bündelt den signierten `vmctl`-Helfer

**Pro** *(einmaliger Kauf: Microsoft Store unter Windows, Lizenzschlüssel von [wslmanager.com/buy](https://wslmanager.com/buy/) unter macOS und für Installationen außerhalb des Stores — niemals ein Abonnement)*
- [x] **AI Workspace** — Hermes Agent, OpenClaw, Open WebUI und OpenCode in einer eigenen, isolierten WSL-Distribution betreiben
- [x] **Ein Modell und Endpunkt für alle KI-Tools** — API-Endpunkt, Schlüssel und Modell des KI-Assistenten aus den Einstellungen verwenden auch OpenCode, OpenClaw und Hermes; einmal festlegen, und ein später installiertes Tool erhält sie ebenfalls
- [x] **KI-Assistent mit Werkzeugen** — der eingebaute Chat kann Ihr WSL wirklich *bedienen*: er listet und untersucht Distributionen, führt Befehle aus, bearbeitet die Konfiguration, legt Snippets an, bindet Datenträger ein und verpackt Distributionen über dieselben Werkzeuge, die der MCP-Server bereitstellt
- [x] **Jeder KI-Lauf, der eine Instanz verändert, wird als Snippet gespeichert** — mit den ausgeführten Befehlen und dem, was jedes Werkzeug gemeldet hat, verlinkt aus dem Chat, damit Sie ihn prüfen, auf einer frischen Instanz erneut ausführen oder teilen können
- [x] **KI in der Sandbox** — eine Wegwerf-Ubuntu-Distribution hochziehen und einem KI-Chat Zugriff *nur* auf das Innere dieser Sandbox geben
- [x] **Aufgabenliste** — geben Sie dem Assistenten eine Liste und lassen Sie ihn sie abarbeiten, Punkt für Punkt abgehakt
- [x] **MCP-Server** — WSL für Claude Desktop, Claude Code, opencode und andere MCP-Clients verfügbar machen
- [x] **Web-Dashboard** — alles vom Telefon oder einem anderen Rechner aus verwalten: QR-Code scannen, die ganze App im Browser bekommen, auf Wunsch über einen Cloudflare-Tunnel auch außerhalb Ihres Netzwerks

> Die KI-Funktionen laufen mit Zugangsdaten, die **Sie** mitbringen — Ihrem
> eigenen OpenAI-kompatiblen API-Schlüssel. Es wird kein KI-Dienst gehostet
> oder mitgeliefert, es gibt kein Kontingent, und keine Anfrage läuft über
> fremde Server. Pro schaltet die Funktionen in der App frei; es kauft kein
> KI-Guthaben. Siehe [Free vs Pro](https://github.com/bostrot/wslmanager/wiki/Pro-Version).

> **Warum gibt es überhaupt eine kostenpflichtige Stufe?** WSL Manager ist seit
> 2021 ein Ein-Personen-Projekt in der Freizeit, und jede Funktion oben — die
> kostenlosen eingeschlossen — entstand an Abenden und Wochenenden. Ihre
> Distributionen und VMs zu verwalten ist kostenlos und bleibt es, und die
> ganze App bleibt quelloffen. Pro ist die KI-Schicht obendrauf, und was sie
> einbringt, macht aus Wartung und neuen Funktionen geplante, regelmäßige
> Arbeit statt dessen, was an Zeit übrig bleibt. Einmal kaufen, für immer
> behalten — und Sie finanzieren direkt die nächste Version.

> 🎁 **Zum Start — die ersten 100 Personen bekommen Pro kostenlos.** Öffnen Sie
> die Kasse mit bereits eingetragenem Code `START100`, und Ihr Lizenzschlüssel
> steht auf der nächsten Seite: [**Windows**](https://buy.stripe.com/5kQeVd6ECgur3wJ2TO1Fe03?prefilled_promo_code=START100) ·
> [**macOS**](https://buy.stripe.com/dRm00jbYWfqnaZb1PK1Fe02?prefilled_promo_code=START100).
> Eine Lizenz pro Person; sind die 100 vergeben, funktioniert der Code nicht mehr.

## 🤖 KI-Assistent & MCP *(Pro)*

Alles in diesem Abschnitt gehört zu **Pro**; die kostenlose App hat davon nichts.

Der KI-Assistent ist ein **Agent**, nicht bloß ein Chatfenster: er bekommt
denselben Werkzeugsatz, den der MCP-Server bereitstellt. Fragen Sie „welche
Distributionen habe ich?“ oder „installiere Ubuntu und setze meinen
Standardbenutzer“, ruft er echte Werkzeuge gegen Ihr WSL auf, statt zu raten.
Werkzeugaufrufe werden während der Arbeit direkt angezeigt.

**Den Anbieter einrichten** unter **Einstellungen → Bring Your Own AI Key**:
jeder OpenAI-kompatible Endpunkt funktioniert (OpenAI, Azure, ein
LiteLLM-Proxy, Ollama, LM Studio, …). Tragen Sie Basis-URL, Schlüssel und
Modell ein. Die Schaltfläche **Modellliste laden** füllt eine
Autovervollständigung aus dem `/models`-Endpunkt des Anbieters, und
**Verbindung testen** belegt, dass die Zugangsdaten stimmen, bevor Sie den Chat
öffnen.

**Nichts davon gewünscht?** **Einstellungen → Bring Your Own AI Key → KI-Funktionen** schaltet den Assistenten, die Fehlerdiagnose und den AI Workspace aus — nichts KI-Bezogenes wird angezeigt, und es wird keine Workspace-Umgebung für Sie eingerichtet. Er ist aus, bis Sie geantwortet haben: WSL Manager fragt einmal, beim ersten Start nach Installation oder Update, und vorher läuft nichts KI-Bezogenes.

**Sandboxes** (AI Workspace → *Sandbox-Distribution hinzufügen*) erzeugen eine
Wegwerf-Instanz aus einem beliebigen Katalog-Image (standardmäßig das neueste
Ubuntu) — unter Windows eine WSL-Distribution, unter macOS eine aus einem
Cloud-Image erstellte Linux-VM, die für Sie angelegt und gestartet wird. Ihrem
Chat werden nur die `sandbox_*`-Werkzeuge gegeben, die auf genau diese eine
Instanz beschränkt sind — das Modell darf alles *innerhalb* der Sandbox tun und
sieht nie Ihren Host oder eine andere Instanz. Ein ehrlicher Vorbehalt: die
Sandbox selbst hat normalen Internetzugang nach außen, wie jede Distribution
oder VM. Sandbox-Chats nutzen dasselbe angedockte Panel wie der Assistent
(inklusive Aufgabenliste), ihre Verläufe bleiben erhalten, und die
Verlaufsschaltfläche in der Kopfzeile des Chats wechselt zwischen dem
Assistenten und jeder Sandbox-Sitzung.

**Aufgabenliste** — öffnen Sie den Abschnitt *Aufgaben* oben im Chat, tragen Sie
Punkte ein und drücken Sie ▶. Der Assistent arbeitet sie mit seinen Werkzeugen
ab und hakt jeden Punkt ab, sobald er fertig ist; Sie können währenddessen
weitere Aufgaben hinzufügen.

### Externe KI-Clients anbinden (MCP)

Schalten Sie **Einstellungen → MCP-Server** ein (Pro). Er stellt das
MCP-Protokoll unter `http://127.0.0.1:59133/mcp` bereit, nur über das
Loopback-Interface und geschützt durch ein Bearer-Token, das im selben Panel
angezeigt wird. Die Werkzeuge decken den gesamten Lebenszyklus ab — anlegen,
importieren, konfigurieren, ausführen, verpacken und (mit einem
Bestätigungs-Flag) abmelden von Distributionen, dazu Snippets, das Einbinden von
Datenträgern und dauerhafte Terminalsitzungen.

**Claude Desktop** — klicken Sie im MCP-Panel auf **Claude Desktop verbinden**.
Der untenstehende Eintrag wird für Sie in `claude_desktop_config.json`
geschrieben (benötigt Node.js); starten Sie Claude Desktop danach neu. Von Hand,
oder für jeden anderen stdio-MCP-Client, überbrücken Sie den HTTP-Endpunkt mit
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote):

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

**Claude Code** — dieselbe Brücke, ein Befehl:

```bash
claude mcp add wsl-manager -- npx -y mcp-remote http://127.0.0.1:59133/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

**opencode** — tragen Sie es unter `mcp` in Ihrer `opencode.json` (oder `~/.config/opencode/opencode.json`) ein:

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

Jeder MCP-Client, der streamable HTTP spricht, kann auch direkt auf den Endpunkt
zeigen und dabei einen `Authorization: Bearer <TOKEN>`-Header mitschicken, ganz
ohne `mcp-remote`. Um ihn von einem anderen Rechner aus zu erreichen, schalten
Sie im selben Panel den eingebauten **Cloudflare-Tunnel** ein und verwenden die
öffentliche URL, die er ausgibt.

## 📱 Web-Dashboard *(Pro)*

Schalten Sie **Einstellungen → Web-Dashboard** ein (Pro), und die App liefert
für jedes Gerät in Ihrem Netzwerk ein Browser-Dashboard auf Port `59134` aus —
unter Windows wie unter macOS. Scannen Sie den QR-Code aus dem Panel mit Ihrem
Telefon (oder kopieren Sie den Link), und Sie haben die ganze App im Browser:
Instanzen starten, stoppen, duplizieren und löschen, Befehle ausführen,
dauerhafte Terminalsitzungen öffnen, Ihre gespeicherten Snippets ausführen und
jedes weitere Werkzeug (Import, Export, Verpacken, `.wslconfig`, Datenträger,
VM-Erstellung) über generierte Formulare bedienen. Es ist derselbe
Werkzeugsatz, den der KI-Assistent und der MCP-Server verwenden.

Der Zugriff ist durch ein Token geschützt, das Teil des Links ist (`?token=…`),
sodass ein gescannter QR-Code alles ist, was ein Gerät braucht — und ein neu
erzeugtes Token im Panel entwertet jeden bisher herausgegebenen Link. Das
Dashboard lauscht absichtlich auf allen Schnittstellen; schalten Sie im selben
Panel **Über Cloudflare-Tunnel veröffentlichen** um, wenn Sie unterwegs einen
temporären öffentlichen HTTPS-Link brauchen (der QR-Code wechselt dann darauf).
Einmal veröffentlicht, ist das Token das Einzige, was eine Oberfläche schützt,
die Befehle ausführen kann — teilen Sie diesen Link also mit Bedacht.

## 📦 Installieren

<details>
<summary>Microsoft Store</summary>

Diese App ist im [Microsoft Store](https://apps.microsoft.com/store/detail/wsl-manager/9NWS9K95NMJB?hl=en-us&gl=US) erhältlich.
</details>

<details>
<summary>macOS über Homebrew</summary>

```sh
brew install --cask wsl-manager
```

Apple Silicon, macOS 11 oder neuer. Das Cask ist in Homebrew selbst enthalten, ein Tap ist also nicht nötig; `brew upgrade --cask wsl-manager` holt neue Versionen.
</details>

<details>
<summary>Direkter Download</summary>

Sie bekommen diese App als direkten Download von der Seite [Releases](https://github.com/bostrot/wslmanager/releases). Windows wird als Setup-`.exe`, als `.msix` und als portables `.zip` ausgeliefert; macOS als `.dmg`.
</details>

<details>
<summary>Installation über Winget</summary>

```sh
winget install Bostrot.WSLManager
```

</details>

<details>
<summary>Installation über Scoop</summary>

```sh
scoop install extras/wsl2-distro-manager
```

</details>

<details>
<summary>Installation über Chocolatey</summary>

Dieses Paket wird von der Community gepflegt ([@mikeee](https://github.com/mikeee/ChocoPackages)). Es ist kein offizielles Paket.

```sh
choco install wsl2-distro-manager
```

</details>

<details>
<summary>Einen Nightly-Build installieren</summary>

Der letzte Nightly-Build ist als Artefakt im „releaser“-Workflow oder über [diesen Link](https://nightly.link/bostrot/wslmanager/workflows/releaser/main/wsl2-distro-manager-nightly-archive.zip) verfügbar.

</details>

## ⚙️ Build

Stellen Sie sicher, dass [flutter](https://flutter.dev/desktop) installiert ist.

### Windows

```powershell
flutter config --enable-windows-desktop
flutter upgrade

flutter build windows # build it
flutter run -d windows # run it
```

### macOS

VMs werden von `vmctl` erstellt, einem kleinen Swift-Helfer, der
Virtualization.framework steuert — nicht von der Flutter-App selbst. Das
Framework antwortet nur Prozessen, die die Berechtigung
`com.apple.security.virtualization` tragen, und `swift build` fügt sie nicht
hinzu. **Der Helfer muss also gebaut und signiert sein, bevor die App eine VM
starten kann**:

```bash
flutter config --enable-macos-desktop

# Build + sign vmctl and install it for dev runs. Re-run after any change
# under macos/vmctl/ — `flutter run` never rebuilds the helper.
VMCTL_ONLY=1 scripts/build_macos.sh

flutter run -d macos
```

Lässt man diesen Schritt aus, startet die App zwar, aber das Starten einer VM
scheitert mit:

```
VM failed to start: Error Domain=VZErrorDomain Code=2 "The process doesn't
have the "com.apple.security.virtualization" entitlement."
```

Das ist der *Helfer* ohne Berechtigung, nicht die App — die Berechtigungen von
`Runner` selbst stimmen bereits. Der signierte Helfer wird nach
`~/Library/Application Support/WSLManager/bin/vmctl` installiert, und genau dort
suchen Debug-Läufe; fehlt er, greifen sie auf die unsignierte Ausgabe von
`swift build` unter `macos/vmctl/.build/` zurück — was den obigen Fehler
erzeugt.

`scripts/build_macos.sh` ohne `VMCTL_ONLY` signiert genauso und baut danach die
Release-App, wobei der signierte Helfer in `Contents/Resources/` des Bundles
mitgeliefert wird. Für den Bau der App selbst wird das vollständige Xcode
benötigt.

## Autor

👤 **Eric Trenkel**

- Website: [erictrenkel.com](https://erictrenkel.com)
- GitHub: [@bostrot](https://github.com/bostrot)
- LinkedIn: [@erictrenkel](https://linkedin.com/in/erictrenkel)

👥 **Mitwirkende**

[![Contributors](https://contrib.rocks/image?repo=bostrot/wslmanager)](https://github.com/bostrot/wslmanager/graphs/contributors)

## 🤝 Mitmachen

Beiträge, Fehlerberichte und Funktionswünsche sind willkommen!\
Schauen Sie gern auf der [Issues-Seite](https://github.com/bostrot/wslmanager/issues) vorbei.
Ein Blick in den [Contributing Guide](https://github.com/bostrot/wslmanager/blob/main/CONTRIBUTING.md) lohnt sich ebenfalls.

## Zeigen Sie Ihre Unterstützung

Geben Sie ein ⭐️, wenn Ihnen dieses Projekt geholfen hat!

## 📝 Lizenz

Copyright © 2026 [Eric Trenkel](https://github.com/bostrot).\
Dieses Projekt ist [GPL-3.0](https://github.com/bostrot/wslmanager/blob/main/LICENSE)-lizenziert.

---

_Nicht gefunden, wonach Sie gesucht haben? Schauen Sie ins [Wiki](https://github.com/bostrot/wslmanager/wiki)_
