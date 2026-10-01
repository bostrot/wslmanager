<h1 align="center">Bem-vindo ao WSL Manager 👋</h1>

![GitHub Release Date](https://img.shields.io/github/release-date/bostrot/wslmanager?style=for-the-badge)
![GitHub Workflow](https://img.shields.io/github/actions/workflow/status/bostrot/wslmanager/releaser.yml?branch=main&label=nightly&style=for-the-badge)
![GitHub release (latest by date)](https://img.shields.io/github/v/release/bostrot/wslmanager?style=for-the-badge)
[![Documentation](https://img.shields.io/badge/DOCUMENTATION-WIKI-green?style=for-the-badge)](https://github.com/bostrot/wslmanager/wiki)
[![GitLab stars](https://img.shields.io/gitlab/stars/bostrot/wsl2-distro-manager?gitlab_url=https%3A%2F%2Fgitlab.com&label=GitLab&style=for-the-badge)](https://gitlab.com/bostrot/wsl2-distro-manager)
[![Discord](https://img.shields.io/discord/1100070299308937287?style=for-the-badge)](https://discord.gg/fY5uE5WRTP)


<p align='center'>
    <a href='../README.md'>English</a> | <a href='./README_zh.md'>简体中文</a> | <a href='./README_zh_tw.md'>繁體中文</a> | <a href='./README_de.md'>Deutsch</a> | <a href='./README_es.md'>Español</a> | <a href='./README_ja.md'>日本語</a> | <a href='./README_hu.md'>Magyar</a> | Português | <a href='./README_tr.md'>Türkçe</a>
</p>

![WSL Distro Manager no Windows, tema escuro](./images/home-dark.png)

<p align='center'>
    <sub>Mostrado no <b>Windows</b> &middot; o mesmo aplicativo gerencia VMs nativas no <b>macOS</b> &mdash; abra <b>Veja no macOS</b> abaixo</sub>
</p>

<details>
<summary>Prévia com tema claro (Windows)</summary>

![WSL Distro Manager no Windows, tema claro](./images/home-light.png)

</details>

<details>
<summary><b>🍎 Veja no macOS</b> &mdash; máquinas virtuais Linux e macOS nativas pelo framework Virtualization da Apple <i>(beta)</i></summary>

![WSL Manager no macOS, tema escuro](./images/home-macos-dark.png)

![WSL Manager no macOS, tema claro, com o assistente de IA aberto](./images/home-macos-light.png)

</details>

> O **WSL Distro Manager** é uma interface gráfica gratuita e de código aberto
> para o Subsistema do Windows para Linux — e, no macOS, para VMs Linux nativas.
> Instale, copie, renomeie, mova, faça backup e exclua distros do WSL sem
> memorizar um único parâmetro do `wsl.exe` — além de modelos, trechos de
> comandos salvos, montagem de discos, edição do `.wslconfig`, WSL remoto por
> SSH e um servidor MCP que permite a agentes de IA operar seu ambiente WSL. Em
> um Mac, este mesmo aplicativo gerencia máquinas virtuais pelo framework
> Virtualization da Apple.

## 🚀 Recursos

**Gerenciar distros**
- [x] Instale a partir de um catálogo integrado ou traga o seu próprio rootfs
- [x] Copie, renomeie, mova para outra unidade, faça backup e exclua instâncias
- [x] Salve todas as instâncias em uma pasta — com uma lista do que há nela — e restaure-as em outro PC
- [x] Compacte discos virtuais para recuperar o espaço que o WSL nunca devolve
- [x] Veja o que uma instância está consumindo agora — processador, memória e swap, com um gráfico ao vivo
- [x] Suporta Ubuntu, Debian, Alpine, Kali Linux, openSUSE, SLES e qualquer outra coisa que o WSL aceite

**Colocar instâncias no ar mais rápido**
- [x] Use qualquer imagem Docker como distro — o próprio Docker não é necessário
- [x] Empacote uma distro já configurada como um arquivo `.wsl` portátil que instala em qualquer máquina (os modelos foram descontinuados em favor dele)
- [x] Turnkey Linux e outros contêineres LXC (experimental)
- [x] Trechos: mantenha seus comandos de configuração no aplicativo e execute-os em qualquer instância
- [x] Aponte o aplicativo para o seu próprio repositório de imagens rootfs
- [x] Navegue pelos arquivos de uma distro e copie os que escolher para outra instância — sem compartilhamento, sem montagem e sem Explorador

<!-- Unreleased. Containers, Kubernetes and Cloud are built but ship only in
     debug runs (LicenseManager.unreleasedFeaturesVisible, the gate Pro rides
     in a debug build); a release has none of them, so the README must not
     promise them. Lift the comment together with the gate.

**Contêineres Docker e Podman**
- [x] Veja todos os contêineres da máquina — os dois motores ao mesmo tempo — ao lado das suas instâncias
- [x] Inicie, pare, reinicie, remova e acompanhe os logs de um contêiner sem sair do aplicativo
- [x] Apenas interface: ele opera o `docker`/`podman` que você já tem e não instala nada
- [x] O chat de IA e o servidor MCP recebem as mesmas ferramentas de contêiner

**Clusters Kubernetes**
- [x] Todos os clusters do seu kubeconfig, um namespace por vez — pensado para dez clusters com cem aplicações
- [x] Deployments, StatefulSets e DaemonSets com a saúde num relance, filtrados por nome, namespace ou imagem
- [x] Abra uma carga de trabalho para ver seus pods, acompanhar os logs, reiniciar um pod, disparar um rollout restart, escalar ou ler todos os detalhes
- [x] Apenas interface: ele opera o `kubectl` que você já tem e nunca reescreve seu kubeconfig nem troca seu contexto
- [x] O chat de IA e o servidor MCP também leem seus clusters — cargas de trabalho, pods, eventos, uso de recursos e logs de pods pesquisáveis — e só leem: nada ali consegue reiniciar, escalar ou excluir

**Implantar na nuvem** *(beta)*
- [x] Envie uma instância inteira para um servidor novo na Hetzner Cloud em um único passo — o sistema de arquivos raiz é exportado, enviado e iniciado lá como contêiner
- [x] O servidor é criado para você: tamanho, localização e imagem base, com o cloud-init instalando o Docker e autorizando a sua própria chave SSH para o `root`
- [x] Funciona também a partir do macOS: o sistema de arquivos raiz de uma VM Linux é lido do convidado em execução, já que sua imagem de disco é uma máquina inicializável e não algo que um motor de contêineres consiga ler
- [x] Traga-a de volta quando quiser como uma nova instância local, deixando o servidor no ar — no macOS isso restaura para uma cópia da VM de onde ela saiu, que precisa ainda existir e estar parada, porque um sistema de arquivos raiz sozinho não tem kernel para iniciar
- [x] Veja quanto cada servidor custa por mês, ligue e desligue-os e exclua-os pela mesma lista
-->

**Configurar sem editar arquivos à mão**
- [x] systemd, automount, usuário padrão, comando e caminho de inicialização por distro
- [x] Memória, processadores, swap, modo de rede, DNS e o resto do `.wslconfig`
- [x] Monte um disco físico ou um VHD no WSL, com controle de partição e sistema de arquivos
- [x] Compartilhar pastas do host em uma distro ou VM no ponto de montagem que você escolher, somente leitura se quiser — inclusive para o AI Workspace

**Trabalhe do jeito que você já trabalha**
- [x] Abra o Terminal do Windows, o VS Code ou o Explorador diretamente dentro de uma distro
- [x] Cada instância no menu do Terminal do Windows, em dia enquanto o app está aberto — adicionada como um fragmento próprio, então suas configurações do Terminal nunca são alteradas
- [x] Gerencie o WSL em *outra* máquina Windows por SSH
- [x] Sincronize uma distro entre duas máquinas da sua rede
- [x] Alcance uma instância pelo nome: o nome de host é mantido no arquivo hosts, então `ssh ubuntu.wsl` continua funcionando depois de reiniciar
- [x] Mantém-se atualizado: as versões do site e do GitHub baixam e instalam as novidades sozinhas (instalações da Store são atualizadas pela Store)
- [x] Temas claro e escuro, disponível em nove idiomas

**No macOS: máquinas virtuais nativas** *(beta)*
- [x] O mesmo aplicativo gerencia VMs pelo framework Virtualization da Apple em vez do WSL
- [x] Crie VMs Linux a partir de uma ISO de instalação, de uma imagem de nuvem ou de um modelo exportado
- [x] Crie VMs convidadas de macOS a partir de uma imagem de restauração (Apple Silicon)
- [x] Inicie, pare, clone, exporte/importe e transforme VMs em modelos, como faz com as distros
- [x] Execute comandos dentro das VMs por SSH provisionado automaticamente (cloud-init), pela interface, pelo chat de IA ou por clientes MCP
- [x] Um terminal para qualquer VM a partir da sua linha: uma sessão SSH no convidado Linux ou macOS, e o console serial quando um convidado Linux não tem a que se conectar
- [x] Sua própria chave de `~/.ssh` é autorizada em toda VM Linux (e criada, se você não tiver nenhuma), então um simples `ssh usuario@ip-da-vm` também funciona
- [x] Cada VM recebe uma senha de login que você pode consultar na linha dela, para entrar na tela da própria VM
- [x] Defina na mesma linha a conta com que cada caminho SSH entra: o nome de um convidado macOS é digitado no Assistente de Configuração, onde o app não consegue vê-lo
- [x] Compile com `scripts/build_macos.sh` — ele inclui o auxiliar `vmctl` assinado

**Pro** *(compra única: Microsoft Store no Windows, chave de licença em [wslmanager.com/buy](https://wslmanager.com/buy/) no macOS e para instalações fora da Store — nunca assinatura)*
- [x] **AI Workspace** — execute Hermes Agent, OpenClaw, Open WebUI e OpenCode em uma distro WSL dedicada e isolada
- [x] **Um modelo e endpoint para todas as ferramentas de IA** — o endpoint da API, a chave e o modelo do assistente definidos em Configurações são os que OpenCode, OpenClaw e Hermes também usam; defina-os uma vez e uma ferramenta instalada depois também os recebe
- [x] **Assistente de IA com ferramentas** — o chat integrado consegue de fato *operar* seu WSL: ele lista e inspeciona distros, executa comandos, edita configurações, cria trechos, monta discos e empacota distros com as mesmas ferramentas expostas pelo servidor MCP
- [x] **Toda execução da IA que altera uma instância é salva como trecho** — com os comandos executados e o que cada ferramenta relatou, com link no chat, para você revisar, repetir em uma instância nova ou compartilhar
- [x] **IA em sandbox** — suba uma distro Ubuntu descartável e dê a um chat de IA acesso *apenas* ao interior desse sandbox
- [x] **Fila de tarefas** — entregue uma lista ao assistente e deixe-o trabalhar nela, marcando cada item conforme avança
- [x] **Servidor MCP** — exponha o WSL ao Claude Desktop, ao Claude Code, ao opencode e a outros clientes MCP
- [x] **Painel web** — gerencie tudo pelo celular ou por outro computador: leia um QR code, tenha o aplicativo inteiro no navegador e, se quiser, publique-o para fora da sua rede por um túnel do Cloudflare

> Os recursos de IA funcionam com credenciais que **você** traz — a sua própria
> chave de API compatível com OpenAI. Nenhum serviço de IA é hospedado ou
> incluído, não há cota e nenhuma requisição passa pelos servidores de
> terceiros. O Pro desbloqueia os recursos no aplicativo; ele não compra
> créditos de IA. Veja
> [Free vs Pro](https://github.com/bostrot/wslmanager/wiki/Pro-Version).

> **Por que existe uma versão paga?** O WSL Manager é, desde 2021, um projeto de
> uma pessoa só, feito nas horas vagas, e todos os recursos acima — inclusive os
> gratuitos — foram construídos em noites e fins de semana. Gerenciar suas
> distros e VMs é gratuito e continuará sendo, e todo o aplicativo continua de
> código aberto. O Pro é a camada de IA em cima disso, e o que ele traz é o que
> transforma manutenção e novos recursos em trabalho planejado e regular, em vez
> do tempo que sobra. Compre uma vez, fique com ele para sempre, e você estará
> financiando diretamente a próxima versão.

## 🤖 Assistente de IA e MCP *(Pro)*

Tudo nesta seção faz parte do **Pro**; o aplicativo gratuito não tem nada disso.

O assistente de IA é um **agente**, não apenas uma caixa de chat: ele recebe o
mesmo conjunto de ferramentas que o servidor MCP expõe, então, quando você
pergunta "quais distros eu tenho?" ou pede "instale o Ubuntu e defina meu usuário
padrão", ele chama ferramentas reais contra o seu WSL em vez de adivinhar. As
chamadas de ferramenta aparecem ali mesmo enquanto ele trabalha.

**Configure o provedor** em **Configurações → Bring Your Own AI Key**: qualquer
endpoint compatível com OpenAI funciona (OpenAI, Azure, um proxy LiteLLM, Ollama,
LM Studio, …). Informe a URL base, a chave e o modelo. O botão **Carregar lista de
modelos** preenche um autocompletar a partir do `/models` do provedor, e **Testar
conexão** comprova que as credenciais funcionam antes de você abrir o chat.

**Não quer nada disso?** **Configurações → Bring Your Own AI Key → Recursos de IA** desliga o assistente, o diagnóstico de erros e o AI Workspace — nada relacionado à IA é mostrado e nenhum ambiente de trabalho é preparado para você. Fica desligado até você responder: o WSL Manager pergunta uma vez, na primeira inicialização após instalar ou atualizar, e nada relacionado à IA é executado antes disso.

**Sandboxes** (AI Workspace → *Adicionar distro sandbox*) criam uma instância
descartável a partir de qualquer imagem do catálogo (o Ubuntu mais recente, por
padrão) — uma distro WSL no Windows, uma VM Linux originada de uma imagem de nuvem
no macOS, criada e iniciada para você. Ao chat dela são entregues apenas as
ferramentas `sandbox_*`, presas àquela única instância — o modelo pode fazer
qualquer coisa *dentro* do sandbox e jamais enxerga o seu host ou outra instância.
Uma ressalva honesta: o próprio sandbox tem acesso normal à internet, como
qualquer distro ou VM. Os chats de sandbox usam o mesmo painel encaixado do
assistente (fila de tarefas incluída), suas transcrições persistem e o botão de
histórico no cabeçalho do chat alterna entre o assistente e qualquer sessão de
sandbox.

**Fila de tarefas** — abra a seção *Tarefas* no topo do chat, adicione itens e
pressione ▶. O assistente percorre a lista com suas ferramentas e marca cada item
ao concluí-lo; você pode continuar adicionando tarefas enquanto ele trabalha.

### Conectar clientes de IA externos (MCP)

Ative **Configurações → Servidor MCP** (Pro). Ele serve o protocolo MCP em
`http://127.0.0.1:59133/mcp`, apenas em loopback, protegido por um token bearer
exibido no mesmo painel. As ferramentas cobrem o ciclo de vida completo — criar,
importar, configurar, executar, empacotar e (com um sinalizador de confirmação)
desregistrar distros, além de trechos, montagem de discos e sessões de terminal
persistentes.

**Claude Desktop** — clique em **Conectar Claude Desktop** no painel MCP. Ele
escreve a entrada abaixo no `claude_desktop_config.json` para você (requer
Node.js); reinicie o Claude Desktop em seguida. Para fazer isso à mão, ou para
qualquer outro cliente MCP por stdio, faça a ponte do endpoint HTTP com o
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

**Claude Code** — a mesma ponte, um comando:

```bash
claude mcp add wsl-manager -- npx -y mcp-remote http://127.0.0.1:59133/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

**opencode** — adicione-o sob `mcp` no seu `opencode.json` (ou `~/.config/opencode/opencode.json`):

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

Qualquer cliente MCP que fale HTTP em streaming também pode apontar direto para o
endpoint com um cabeçalho `Authorization: Bearer <TOKEN>`, dispensando o
`mcp-remote`. Para alcançá-lo de outra máquina, ative o **túnel do Cloudflare**
embutido no mesmo painel e use a URL pública que ele imprime.

## 📱 Painel web *(Pro)*

Ative **Configurações → Painel web** (Pro) e o aplicativo passa a servir um painel
de navegador na porta `59134` para todos os dispositivos da sua rede — tanto no
Windows quanto no macOS. Leia com o celular o QR code que o painel mostra (ou copie
o link) e você terá o aplicativo inteiro no navegador: iniciar, parar, duplicar e
excluir instâncias, executar comandos, abrir sessões de terminal persistentes,
rodar seus trechos salvos e usar todas as demais ferramentas (importação,
exportação, empacotamento, `.wslconfig`, discos, criação de VMs) por formulários
gerados. É o mesmo conjunto de ferramentas que o assistente de IA e o servidor MCP
usam.

O acesso é protegido por um token que faz parte do link (`?token=…`), de modo que
um QR code lido é tudo de que um dispositivo precisa — e regenerar o token no
painel revoga todos os links distribuídos até então. O painel escuta em todas as
interfaces de propósito; ative **Publicar via túnel do Cloudflare** no mesmo lugar
para obter um link HTTPS público temporário (o QR code passa a apontar para ele)
quando precisar dele fora de casa. Uma vez publicado, o token é a única coisa
protegendo uma superfície capaz de executar comandos, então compartilhe esse link
com cuidado.

## 📦 Instalação

<details>
<summary>Microsoft Store</summary>

Este aplicativo está disponível na [Microsoft Store](https://apps.microsoft.com/store/detail/wsl-manager/9NWS9K95NMJB?hl=en-us&gl=US).
</details>

<details>
<summary>macOS via Homebrew</summary>

```sh
brew install --cask wsl-manager
```

Apple Silicon, macOS 11 ou mais recente. O cask acompanha o próprio Homebrew, por isso não é preciso nenhum tap; `brew upgrade --cask wsl-manager` traz as novas versões.
</details>

<details>
<summary>Download direto</summary>

Você pode obter este aplicativo por download direto na página de [Releases](https://github.com/bostrot/wslmanager/releases). O Windows vem como `.exe` de instalação, `.msix` e `.zip` portátil; o macOS, como `.dmg`.
</details>

<details>
<summary>Instalação via Winget</summary>

```sh
winget install Bostrot.WSLManager
```

</details>

<details>
<summary>Instalação via Scoop</summary>

```sh
scoop install extras/wsl2-distro-manager
```

</details>

<details>
<summary>Instalação via Chocolatey</summary>

Este pacote é mantido pela comunidade ([@mikeee](https://github.com/mikeee/ChocoPackages)). Não é um pacote oficial.

```sh
choco install wsl2-distro-manager
```

</details>

<details>
<summary>Instalar uma versão nightly</summary>

A versão nightly mais recente está disponível como artefato no workflow "releaser" ou por [este link](https://nightly.link/bostrot/wslmanager/workflows/releaser/main/wsl2-distro-manager-nightly-archive.zip).

</details>

## ⚙️ Build

Verifique se o [flutter](https://flutter.dev/desktop) está instalado.

### Windows

```powershell
flutter config --enable-windows-desktop
flutter upgrade

flutter build windows # build it
flutter run -d windows # run it
```

### macOS

As VMs são criadas pelo `vmctl`, um pequeno auxiliar em Swift que opera o
Virtualization.framework — não pelo aplicativo Flutter em si. O framework só
responde a processos que carregam a permissão `com.apple.security.virtualization`,
e o `swift build` não a adiciona, então **o auxiliar precisa ser compilado e
assinado antes que o aplicativo consiga iniciar uma VM**:

```bash
flutter config --enable-macos-desktop

# Build + sign vmctl and install it for dev runs. Re-run after any change
# under macos/vmctl/ — `flutter run` never rebuilds the helper.
VMCTL_ONLY=1 scripts/build_macos.sh

flutter run -d macos
```

Pule esse passo e o aplicativo abre normalmente, mas iniciar uma VM falha com:

```
VM failed to start: Error Domain=VZErrorDomain Code=2 "The process doesn't
have the "com.apple.security.virtualization" entitlement."
```

É o *auxiliar* sem a permissão, não o aplicativo — as permissões do próprio
`Runner` já estão corretas. O auxiliar assinado é instalado em
`~/Library/Application Support/WSLManager/bin/vmctl`, que é onde as execuções de
depuração o procuram; sem ele, elas recorrem à saída não assinada do `swift build`
em `macos/vmctl/.build/`, que é o que produz o erro acima.

O `scripts/build_macos.sh` sem `VMCTL_ONLY` faz a mesma assinatura e depois compila
o aplicativo de release, incluindo o auxiliar assinado no `Contents/Resources/` do
bundle. Compilar o próprio aplicativo exige o Xcode completo.

## Autor

👤 **Eric Trenkel**

- Site: [erictrenkel.com](https://erictrenkel.com)
- GitHub: [@bostrot](https://github.com/bostrot)
- LinkedIn: [@erictrenkel](https://linkedin.com/in/erictrenkel)

👥 **Colaboradores**

[![Contributors](https://contrib.rocks/image?repo=bostrot/wslmanager)](https://github.com/bostrot/wslmanager/graphs/contributors)

## 🤝 Contribuição

Contribuições, problemas e pedidos de recursos são bem-vindos!\
Sinta-se à vontade para conferir a [página de issues](https://github.com/bostrot/wslmanager/issues).
Você também pode dar uma olhada no [guia de contribuição](https://github.com/bostrot/wslmanager/blob/main/CONTRIBUTING.md).

## Mostre seu apoio

Dê uma ⭐️ se este projeto ajudou você!

## 📝 Licença

Copyright © 2026 [Eric Trenkel](https://github.com/bostrot).\
Este projeto está licenciado sob a [GPL-3.0](https://github.com/bostrot/wslmanager/blob/main/LICENSE).

---

_Não encontrou o que procurava? Dê uma olhada na [Wiki](https://github.com/bostrot/wslmanager/wiki)_
