<h1 align="center">¡Bienvenido a WSL Manager! 👋</h1>

![GitHub Release Date](https://img.shields.io/github/release-date/bostrot/wslmanager?style=for-the-badge)
![GitHub Workflow](https://img.shields.io/github/actions/workflow/status/bostrot/wslmanager/releaser.yml?branch=main&label=nightly&style=for-the-badge)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/bostrot/wslmanager?style=for-the-badge)
[![Documentation](https://img.shields.io/badge/DOCUMENTATION-WIKI-green?style=for-the-badge)](https://github.com/bostrot/wslmanager/wiki)
[![GitLab stars](https://img.shields.io/gitlab/stars/bostrot/wsl2-distro-manager?gitlab_url=https%3A%2F%2Fgitlab.com&label=GitLab&style=for-the-badge)](https://gitlab.com/bostrot/wsl2-distro-manager)
[![Discord](https://img.shields.io/discord/1100070299308937287?style=for-the-badge)](https://discord.gg/fY5uE5WRTP)


<p align='center'>
    <a href='../README.md'>English</a> | <a href='./README_zh.md'>简体中文</a> | <a href='./README_zh_tw.md'>繁體中文</a> | <a href='./README_de.md'>Deutsch</a> | Español | <a href='./README_ja.md'>日本語</a> | <a href='./README_hu.md'>Magyar</a> | <a href='./README_pt.md'>Português</a> | <a href='./README_tr.md'>Türkçe</a>
</p>

![WSL Distro Manager en Windows, tema oscuro](./images/home-dark.png)

<p align='center'>
    <sub>Mostrado en <b>Windows</b> &middot; la misma app gestiona VMs nativas en <b>macOS</b> &mdash; despliega <b>Verlo en macOS</b> más abajo</sub>
</p>

<details>
<summary>Vista previa con tema claro (Windows)</summary>

![WSL Distro Manager en Windows, tema claro](./images/home-light.png)

</details>

<details>
<summary><b>🍎 Verlo en macOS</b> &mdash; máquinas virtuales Linux y macOS nativas mediante el framework Virtualization de Apple <i>(beta)</i></summary>

![WSL Manager en macOS, tema oscuro](./images/home-macos-dark.png)

![WSL Manager en macOS, tema claro, con el asistente de IA abierto](./images/home-macos-light.png)

</details>

> **WSL Distro Manager** es una interfaz gráfica gratuita y de código abierto
> para el Subsistema de Windows para Linux — y, en macOS, para VMs Linux
> nativas. Instala, copia, renombra, mueve, respalda y elimina distros de WSL
> sin memorizar ni una sola opción de `wsl.exe` — además de plantillas,
> fragmentos de comandos guardados, montaje de discos, edición de `.wslconfig`,
> WSL remoto por SSH y un servidor MCP que permite a los agentes de IA manejar
> tu entorno WSL. En un Mac, esta misma app gestiona máquinas virtuales a
> través del framework Virtualization de Apple.

## 🚀 Características

**Gestionar distros**
- [x] Instala desde un catálogo integrado o trae tu propio rootfs
- [x] Copia, renombra, mueve a otra unidad, respalda y elimina instancias
- [x] Guarda todas las instancias en una carpeta —con una lista de lo que contiene— y restáuralas en otro PC
- [x] Compacta los discos virtuales para recuperar el espacio que WSL nunca devuelve
- [x] Observa lo que una instancia está consumiendo ahora mismo: procesador, memoria e intercambio, con un gráfico en vivo
- [x] Admite Ubuntu, Debian, Alpine, Kali Linux, openSUSE, SLES y cualquier otra cosa que WSL acepte

**Poner instancias en marcha más rápido**
- [x] Usa cualquier imagen de Docker como distro — no hace falta Docker
- [x] Empaqueta una distro ya configurada como un archivo `.wsl` portátil que se instala en cualquier máquina (las plantillas quedan obsoletas frente a esto)
- [x] Turnkey Linux y otros contenedores LXC (experimental)
- [x] Fragmentos: guarda tus comandos de configuración en la app y ejecútalos en cualquier instancia
- [x] Apunta la app a tu propio repositorio de imágenes rootfs
- [x] Explora los archivos de una distro y copia los que elijas a otra instancia — sin recursos compartidos, sin montajes y sin Explorador

<!-- Unreleased. Containers, Kubernetes and Cloud are built but ship only in
     debug runs (LicenseManager.unreleasedFeaturesVisible, the gate Pro rides
     in a debug build); a release has none of them, so the README must not
     promise them. Lift the comment together with the gate.

**Contenedores Docker y Podman**
- [x] Ve todos los contenedores de la máquina — ambos motores a la vez — junto a tus instancias
- [x] Arranca, detén, reinicia, elimina y sigue los registros de un contenedor sin salir de la app
- [x] Solo interfaz: maneja el `docker`/`podman` que ya tienes y no instala nada
- [x] El chat de IA y el servidor MCP reciben las mismas herramientas de contenedores

**Clústeres de Kubernetes**
- [x] Todos los clústeres de tu kubeconfig, un espacio de nombres a la vez — pensado para diez clústeres con cien aplicaciones
- [x] Deployments, StatefulSets y DaemonSets con su estado de un vistazo, filtrados por nombre, espacio de nombres o imagen
- [x] Abre una carga de trabajo para ver sus pods, seguir sus registros, reiniciar un pod, lanzar un rollout restart, escalar o leer todos los detalles
- [x] Solo interfaz: maneja el `kubectl` que ya tienes, y nunca reescribe tu kubeconfig ni cambia tu contexto
- [x] El chat con IA y el servidor MCP también leen tus clústeres — cargas de trabajo, pods, eventos, uso de recursos y registros de pods con búsqueda — y solo los leen: nada de eso puede reiniciar, escalar ni eliminar

**Desplegar en la nube** *(beta)*
- [x] Lleva una instancia entera a un servidor nuevo de Hetzner Cloud en un solo paso — el sistema de archivos raíz se exporta, se sube y se arranca allí como contenedor
- [x] El servidor se crea por ti: tamaño, ubicación e imagen base, con cloud-init instalando Docker y autorizando tu propia clave SSH para `root`
- [x] También funciona desde macOS: el sistema de archivos raíz de una VM Linux se lee del invitado en marcha, porque su imagen de disco es una máquina arrancable y no algo que un motor de contenedores pueda leer
- [x] Recupérala cuando quieras como una nueva instancia local, dejando el servidor en marcha — en macOS se restaura sobre una copia de la VM desde la que se desplegó, que debe seguir existiendo y estar detenida, porque un sistema de archivos raíz por sí solo no tiene núcleo con el que arrancar
- [x] Consulta lo que cuesta cada servidor al mes, enciéndelos y apágalos, y elimínalos desde la misma lista
-->

**Configurar sin editar archivos a mano**
- [x] systemd, automount, usuario por defecto, comando y ruta de inicio por distro
- [x] Memoria, procesadores, swap, modo de red, DNS y el resto de `.wslconfig`
- [x] Monta un disco físico o un VHD en WSL, con control de partición y sistema de archivos
- [x] Compartir carpetas del host en una distro o VM en el punto de montaje que elijas, en solo lectura si quieres — también para el AI Workspace

**Trabajar como ya trabajas**
- [x] Abre Windows Terminal, VS Code o el Explorador directamente dentro de una distro
- [x] Cada instancia en el menú de Windows Terminal, al día mientras la app está abierta: se añade como un fragmento propio, así que tu configuración de Terminal nunca se modifica
- [x] Gestiona WSL en *otra* máquina Windows por SSH
- [x] Sincroniza una distro entre dos máquinas de tu red
- [x] Alcanza una instancia por su nombre: su nombre de host se mantiene en el archivo hosts, así que `ssh ubuntu.wsl` sigue funcionando tras reiniciar
- [x] Se mantiene al día: las versiones de la web y de GitHub descargan e instalan las novedades por su cuenta (las instalaciones de la Store las actualiza la Store)
- [x] Temas oscuro y claro, disponible en nueve idiomas

**En macOS: máquinas virtuales nativas** *(beta)*
- [x] La misma app gestiona VMs con el framework Virtualization de Apple en lugar de WSL
- [x] Crea VMs Linux desde una ISO de instalación, una imagen de nube o una plantilla exportada
- [x] Crea VMs invitadas de macOS desde una imagen de restauración (Apple Silicon)
- [x] Arranca, detén, clona, exporta/importa y convierte VMs en plantillas igual que las distros
- [x] Ejecuta comandos dentro de las VMs por SSH aprovisionado automáticamente (cloud-init), desde la interfaz, el chat de IA o clientes MCP
- [x] Una terminal para cualquier VM desde su fila: una sesión SSH en el invitado Linux o macOS, y la consola serie cuando en Linux no hay nada a lo que conectarse
- [x] Tu propia clave de `~/.ssh` queda autorizada en cada VM Linux (y se crea si no tienes ninguna), así que un simple `ssh usuario@ip-vm` también funciona
- [x] Cada VM recibe una contraseña de acceso que puedes consultar en su fila, para iniciar sesión en la pantalla de la propia VM
- [x] Define en esa misma fila la cuenta con la que inicia sesión cada ruta SSH: el nombre de un invitado macOS se escribe en el Asistente de Configuración, donde la app no puede verlo
- [x] Compila con `scripts/build_macos.sh` — incluye el ayudante `vmctl` firmado

**Pro** *(pago único: Microsoft Store en Windows, clave de licencia en [wslmanager.com/buy](https://wslmanager.com/buy/) para macOS y para instalaciones fuera de la Store — nunca una suscripción)*
- [x] **AI Workspace** — ejecuta Hermes Agent, OpenClaw, Open WebUI y OpenCode en una distro de WSL dedicada y aislada
- [x] **Un modelo y endpoint para todas las herramientas de IA** — el endpoint de la API, la clave y el modelo del asistente definidos en Ajustes son los que usan también OpenCode, OpenClaw y Hermes; defínelos una vez y una herramienta instalada después también los recibe
- [x] **Asistente de IA con herramientas** — el chat integrado puede *operar* tu WSL de verdad: lista e inspecciona distros, ejecuta comandos, edita la configuración, crea fragmentos, monta discos y empaqueta distros con las mismas herramientas que expone el servidor MCP
- [x] **Cada ejecución de la IA que cambia una instancia se guarda como fragmento** — con los comandos ejecutados y lo que informó cada herramienta, enlazado desde el chat, para que puedas revisarla, repetirla en una instancia nueva o compartirla
- [x] **IA en un sandbox** — levanta una distro Ubuntu desechable y da a un chat de IA acceso *solo* al interior de ese sandbox
- [x] **Cola de tareas** — entrégale al asistente una lista y déjalo trabajar, marcando cada punto a medida que avanza
- [x] **Servidor MCP** — expón WSL a Claude Desktop, Claude Code, opencode y otros clientes MCP
- [x] **Panel web** — gestiónalo todo desde tu teléfono u otro ordenador: escanea un código QR, obtén la app entera en un navegador y publícala opcionalmente fuera de tu red mediante un túnel de Cloudflare

> Las funciones de IA usan credenciales que aportas **tú** — tu propia clave de
> API compatible con OpenAI. No se aloja ni se incluye ningún servicio de IA,
> no hay cuota y ninguna petición pasa por servidores ajenos. Pro desbloquea
> las funciones en la app; no compra crédito de IA. Consulta
> [Free vs Pro](https://github.com/bostrot/wslmanager/wiki/Pro-Version).

> **¿Por qué existe una versión de pago?** WSL Manager es, desde 2021, un
> proyecto de una sola persona hecho en su tiempo libre, y cada función de
> arriba — también las gratuitas — se construyó por las tardes y los fines de
> semana. Gestionar tus distros y VMs es gratis y seguirá siéndolo, y toda la
> app sigue siendo de código abierto. Pro es la capa de IA que va encima, y lo
> que aporta es lo que convierte el mantenimiento y las nuevas funciones en
> trabajo planificado y regular en lugar del tiempo que sobre. Cómpralo una
> vez, consérvalo para siempre, y estarás financiando directamente la próxima
> versión.

> 🎁 **Oferta de lanzamiento: las primeras 100 personas se llevan Pro gratis.**
> Abre el pago con el código `START100` ya aplicado y tendrás tu clave de
> licencia en la página siguiente: [**Windows**](https://buy.stripe.com/5kQeVd6ECgur3wJ2TO1Fe03?prefilled_promo_code=START100) ·
> [**macOS**](https://buy.stripe.com/dRm00jbYWfqnaZb1PK1Fe02?prefilled_promo_code=START100).
> Una licencia por persona; cuando se agoten las 100, el código dejará de funcionar.

## 🤖 Asistente de IA y MCP *(Pro)*

Todo lo de esta sección forma parte de **Pro**; la app gratuita no incluye nada de esto.

El asistente de IA es un **agente**, no una simple caja de chat: recibe el mismo
conjunto de herramientas que expone el servidor MCP, así que cuando preguntas
«¿qué distros tengo?» o «instala Ubuntu y configura mi usuario por defecto»,
llama a herramientas reales contra tu WSL en lugar de adivinar. Las llamadas a
herramientas se muestran en línea mientras trabaja.

**Configura el proveedor** en **Ajustes → Bring Your Own AI Key**: sirve
cualquier endpoint compatible con OpenAI (OpenAI, Azure, un proxy LiteLLM,
Ollama, LM Studio, …). Introduce la URL base, la clave y el modelo. El botón
**Cargar lista de modelos** rellena un autocompletado desde el `/models` del
proveedor, y **Probar conexión** demuestra que las credenciales funcionan antes
de abrir el chat.

**¿No quieres nada de esto?** **Ajustes → Bring Your Own AI Key → Funciones de IA** desactiva el asistente, el diagnóstico de errores y el AI Workspace: no se muestra nada relacionado con la IA y no se prepara ningún entorno de trabajo por ti. Está desactivado hasta que respondas: WSL Manager lo pregunta una vez, en el primer inicio tras instalar o actualizar, y antes de eso no se ejecuta nada relacionado con la IA.

**Sandboxes** (AI Workspace → *Añadir distro sandbox*) crean una instancia
desechable a partir de cualquier imagen del catálogo (el Ubuntu más reciente por
defecto) — una distro de WSL en Windows, una VM Linux partiendo de una imagen de
nube en macOS, que se crea y arranca por ti. A su chat solo se le entregan las
herramientas `sandbox_*`, limitadas a esa única instancia: el modelo puede hacer
cualquier cosa *dentro* del sandbox y nunca ve tu anfitrión ni ninguna otra
instancia. Una salvedad honesta: el sandbox en sí tiene acceso normal a internet
hacia fuera, como cualquier distro o VM. Los chats de sandbox usan el mismo panel
acoplado que el asistente (cola de tareas incluida), sus transcripciones
persisten, y el botón de historial de la cabecera del chat alterna entre el
asistente y cualquier sesión de sandbox.

**Cola de tareas** — abre la sección *Tareas* en la parte superior del chat,
añade elementos y pulsa ▶. El asistente los recorre con sus herramientas y va
marcando cada uno al terminarlo; puedes seguir añadiendo tareas mientras
trabaja.

### Conectar clientes de IA externos (MCP)

Activa **Ajustes → Servidor MCP** (Pro). Sirve el protocolo MCP en
`http://127.0.0.1:59133/mcp`, solo en loopback y protegido por un token bearer
que se muestra en el mismo panel. Las herramientas cubren el ciclo completo:
crear, importar, configurar, ejecutar, empaquetar y (con una marca de
confirmación) dar de baja distros, además de fragmentos, montaje de discos y
sesiones de terminal persistentes.

**Claude Desktop** — pulsa **Conectar Claude Desktop** en el panel MCP. Escribe
por ti la entrada de abajo en `claude_desktop_config.json` (necesita Node.js);
reinicia Claude Desktop después. Para hacerlo a mano, o para cualquier otro
cliente MCP por stdio, puentea el endpoint HTTP con
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

**Claude Code** — el mismo puente, un solo comando:

```bash
claude mcp add wsl-manager -- npx -y mcp-remote http://127.0.0.1:59133/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

**opencode** — añádelo bajo `mcp` en tu `opencode.json` (o `~/.config/opencode/opencode.json`):

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

Cualquier cliente MCP que hable HTTP en streaming puede apuntar directamente al
endpoint con una cabecera `Authorization: Bearer <TOKEN>`, sin pasar por
`mcp-remote`. Para llegar a él desde otra máquina, activa el **túnel de
Cloudflare** integrado en ese mismo panel y usa la URL pública que imprime.

## 📱 Panel web *(Pro)*

Activa **Ajustes → Panel web** (Pro) y la app servirá un panel de navegador en
el puerto `59134` para todos los dispositivos de tu red, tanto en Windows como
en macOS. Escanea con el móvil el código QR que muestra el panel (o copia el
enlace) y tendrás la app entera en un navegador: arrancar, detener, duplicar y
eliminar instancias, ejecutar comandos, abrir sesiones de terminal persistentes,
lanzar tus fragmentos guardados y manejar todas las demás herramientas
(importar, exportar, empaquetado, `.wslconfig`, discos, creación de VMs)
mediante formularios generados. Es el mismo conjunto de herramientas que usan el
asistente de IA y el servidor MCP.

El acceso está protegido por un token que forma parte del enlace (`?token=…`),
de modo que un código QR escaneado es todo lo que necesita un dispositivo — y
regenerar el token en el panel revoca todos los enlaces repartidos hasta
entonces. El panel escucha en todas las interfaces a propósito; activa
**Publicar mediante túnel de Cloudflare** en ese mismo sitio para obtener un
enlace HTTPS público temporal (el código QR cambia a él) cuando lo necesites
fuera de casa. Una vez publicado, el token es lo único que protege una
superficie capaz de ejecutar comandos, así que comparte ese enlace con cuidado.

## 📦 Instalación

<details>
<summary>Microsoft Store</summary>

Esta app está disponible en la [Microsoft Store](https://apps.microsoft.com/store/detail/wsl-manager/9NWS9K95NMJB?hl=en-us&gl=US).
</details>

<details>
<summary>macOS con Homebrew</summary>

```sh
brew install --cask wsl-manager
```

Apple Silicon, macOS 11 o posterior. El cask viene con el propio Homebrew, así que no hace falta ningún tap; `brew upgrade --cask wsl-manager` recoge las nuevas versiones.
</details>

<details>
<summary>Descarga directa</summary>

Puedes conseguir esta app mediante descarga directa desde la página de [Releases](https://github.com/bostrot/wslmanager/releases). Windows se distribuye como `.exe` de instalación, `.msix` y `.zip` portátil; macOS como `.dmg`.
</details>

<details>
<summary>Instalación con Winget</summary>

```sh
winget install Bostrot.WSLManager
```

</details>

<details>
<summary>Instalación con Scoop</summary>

```sh
scoop install extras/wsl2-distro-manager
```

</details>

<details>
<summary>Instalación con Chocolatey</summary>

Este paquete lo mantiene la comunidad ([@mikeee](https://github.com/mikeee/ChocoPackages)). No es un paquete oficial.

```sh
choco install wsl2-distro-manager
```

</details>

<details>
<summary>Instalar una compilación nocturna</summary>

La última compilación nocturna está disponible como artefacto en el flujo de trabajo «releaser» o a través de [este enlace](https://nightly.link/bostrot/wslmanager/workflows/releaser/main/wsl2-distro-manager-nightly-archive.zip).

</details>

## ⚙️ Build

Asegúrate de tener [flutter](https://flutter.dev/desktop) instalado.

### Windows

```powershell
flutter config --enable-windows-desktop
flutter upgrade

flutter build windows # build it
flutter run -d windows # run it
```

### macOS

Las VMs las crea `vmctl`, un pequeño ayudante en Swift que maneja
Virtualization.framework — no la app de Flutter. El framework solo responde a
procesos que llevan el permiso `com.apple.security.virtualization`, y `swift
build` no lo añade, así que **el ayudante debe compilarse y firmarse antes de
que la app pueda arrancar una VM**:

```bash
flutter config --enable-macos-desktop

# Build + sign vmctl and install it for dev runs. Re-run after any change
# under macos/vmctl/ — `flutter run` never rebuilds the helper.
VMCTL_ONLY=1 scripts/build_macos.sh

flutter run -d macos
```

Si te saltas ese paso, la app se abre sin problemas, pero arrancar una VM falla
con:

```
VM failed to start: Error Domain=VZErrorDomain Code=2 "The process doesn't
have the "com.apple.security.virtualization" entitlement."
```

Es el *ayudante* al que le falta el permiso, no la app: los permisos de `Runner`
ya son correctos. El ayudante firmado se instala en `~/Library/Application
Support/WSLManager/bin/vmctl`, que es donde lo buscan las ejecuciones de
depuración; sin él, recurren a la salida sin firmar de `swift build` en
`macos/vmctl/.build/`, que es lo que produce el error anterior.

`scripts/build_macos.sh` sin `VMCTL_ONLY` hace la misma firma y luego compila la
app de release, incluyendo el ayudante firmado en `Contents/Resources/` del
bundle. Compilar la app en sí requiere Xcode completo.

## Autor

👤 **Eric Trenkel**

- Sitio web: [erictrenkel.com](https://erictrenkel.com)
- GitHub: [@bostrot](https://github.com/bostrot)
- LinkedIn: [@erictrenkel](https://linkedin.com/in/erictrenkel)

👥 **Colaboradores**

[![Contributors](https://contrib.rocks/image?repo=bostrot/wslmanager)](https://github.com/bostrot/wslmanager/graphs/contributors)

## 🤝 Contribuir

¡Las contribuciones, informes de errores y peticiones de funciones son bienvenidos!\
Echa un vistazo a la [página de issues](https://github.com/bostrot/wslmanager/issues).
También puedes consultar la [guía de contribución](https://github.com/bostrot/wslmanager/blob/main/CONTRIBUTING.md).

## Muestra tu apoyo

¡Danos una ⭐️ si este proyecto te ha ayudado!

## 📝 Licencia

Copyright © 2026 [Eric Trenkel](https://github.com/bostrot).\
Este proyecto tiene licencia [GPL-3.0](https://github.com/bostrot/wslmanager/blob/main/LICENSE).

---

_¿No has encontrado lo que buscabas? Echa un vistazo a la [Wiki](https://github.com/bostrot/wslmanager/wiki)_
