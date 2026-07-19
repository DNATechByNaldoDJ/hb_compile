# hb_compile

[English](README.md) | **Português (Brasil)**

Camada de build para compilar o Harbour a partir de um checkout local. Por
padrao, se o fonte ainda nao existir, o projeto clona:

```text
https://github.com/harbour/core.git
```

em:

```text
scratch\harbour-core
```

Esta pasta organiza perfis, logs, dependencias locais, ferramentas baixadas e
destinos de instalacao em `out\`, sem misturar esses artefatos com o codigo do
Harbour.

## Estrutura

- `config\profiles.json`: perfis de compilacao e origem padrao do Harbour.
- `config\dependencies.json`: catalogo de dependencias opcionais usadas no modo `-Full`.
- `config\docker\linux\`: Dockerfiles para builds Linux reprodutiveis.
- `build-sandbox.ps1`: executa perfis Windows portateis em um Windows Sandbox limpo.
- `config\external-deps.example.ps1`: modelo para dependencias opcionais `HB_WITH_*`.
- `HOWTO.pt-BR.md`: guia central do processo de build, perfis, logs e troubleshooting.
- `DEPENDENCIES.pt-BR.md`: guia de dependencias, conjuntos e wrappers full.
- `OPENADS.pt-BR.md`: detalhes do fallback OpenADS usado pelo contrib `rddads`.
- `HBDAP.pt-BR.md`: integração opcional do depurador DAP para Harbour.
- `TODO.pt-BR.md`: roadmap de builds, integrações e validações.
- `BUILD-SANDBOX.pt-BR.md`: especificação, limitações e validação no Windows Sandbox.
- `scripts\Invoke-HarbourBuild.ps1`: executor principal.
- `scripts\Bootstrap-Tools.ps1`: baixa ferramentas locais como Zig e MinGW-w64.
- `scripts\Show-Status.ps1`: mostra HarbourRoot, toolchains, win-make e saidas.
- `scripts\Test-HarbourInstall.ps1`: compila `samples\hello.prg` com um build instalado.
- `out\`: instalacoes geradas por perfil.
- `logs\`: logs completos de build.
- `tools\`: ferramentas baixadas localmente.
- `scratch\`: area temporaria; por padrao recebe o checkout `harbour-core`.

## Uso rapido

Ver status:

```powershell
.\scripts\Show-Status.ps1
```

No primeiro build, se `scratch\harbour-core` ainda nao existir, o Harbour sera
clonado automaticamente do repositorio padrao.

Listar perfis:

```powershell
.\scripts\Invoke-HarbourBuild.ps1 -ListProfiles
```

Ver o comando sem compilar:

```powershell
.\build-zig.ps1 -DryRun
```

Incluir opcionalmente o hbdap no build nativo de contribs:

```powershell
.\build-zig.ps1 -WithHbdap
.\build-full-linux-wsl.ps1 -WithHbdap -IgnoreDependency qt
```

Sem `-WithHbdap`, o build do Harbour permanece inalterado. Consulte
[HBDAP.pt-BR.md](HBDAP.pt-BR.md).

Compilar também OpenADS e habilitar `rddads` no Linux:

```powershell
.\build-full-linux-wsl.ps1 -WithOpenAds -IgnoreDependency qt
.\build-full-linux-docker.ps1 -WithOpenAds -IgnoreDependency qt
```

Consulte [OPENADS.pt-BR.md](OPENADS.pt-BR.md).

Executar um build isolado no Windows Sandbox:

```powershell
.\build-sandbox.ps1 -BuildProfile zig -Clean
```

O launcher do Sandbox serve para validar ambiente limpo e reprodutibilidade,
não como caminho principal de desenvolvimento. Os wrappers locais são mais
rápidos para builds rotineiros e incrementais. Consulte
[BUILD-SANDBOX.pt-BR.md](BUILD-SANDBOX.pt-BR.md).
Use `-LocalWorkspace` para manter o I/O do build no disco do convidado quando o
repositório estiver em armazenamento externo ou de rede instável.

O Windows Sandbox aceita somente uma instancia por vez. O launcher detecta uma
VM ativa antes de iniciar e aguarda o resultado independentemente do processo
intermediario `WindowsSandbox.exe`. Use `-SandboxTimeoutMinutes` para alterar o
limite padrao de 240 minutos.

## Origem do Harbour

A origem padrao fica em `config\profiles.json`:

```json
{
  "harbourRepository": "https://github.com/harbour/core.git",
  "harbourRoot": "scratch\\harbour-core"
}
```

Para compilar usando outro fork ou repositorio em outro checkout:

```powershell
.\build-zig.ps1 -HarbourRepository https://github.com/seu-usuario/core.git -HarbourRoot scratch\harbour-core-fork
```

Para usar um checkout que ja existe em outro lugar:

```powershell
.\build-zig.ps1 -HarbourRoot ..\harbour-core
```

Para clonar uma branch, tag ou commit especifico quando o `HarbourRoot`
informado ainda nao existe:

```powershell
.\build-zig.ps1 -HarbourRepository https://github.com/harbour/core.git -HarbourRef minha-branch
```

Se o `HarbourRoot` ja existir, o script nao troca branch automaticamente; nesse
caso use `git -C <HarbourRoot> checkout <ref>` antes do build.

## Build no padrao pre existente

Usa `win-make.exe` do proprio Harbour e deixa o Harbour autodetectar o
compilador pelo ambiente atual:

```powershell
.\build-standard.ps1 -Clean
```

Para forcar compiladores comuns:

```powershell
.\build-msvc64.ps1 -Clean
.\build-mingw64.ps1 -Clean
```

Os mesmos perfis tambem tem wrappers em modo full, que preparam dependencias
opcionais antes do build:

```powershell
.\build-full-standard.ps1 -Clean
.\build-full-msvc64.ps1 -Clean
.\build-full-mingw64.ps1 -Clean
```

O perfil `msvc64` tenta carregar automaticamente o ambiente do Visual Studio
Build Tools via `vswhere`. Se preferir, abra antes um "Developer PowerShell"
ou chame `vcvarsall.bat` e use `-NoVsDevShell`.

O perfil `mingw64` exige um GCC MinGW-w64/MSYS2 valido. Se o primeiro
`gcc.exe` encontrado for o do Cygwin, o build tenta usar `tools\mingw64` ou
baixar um MinGW-w64 portatil antes de falhar. Para forcar um toolchain
especifico, use `-MinGwPath`:

```powershell
.\build-full-mingw64.ps1 -MinGwPath C:\Tools\xpack-mingw-w64-gcc\bin -IgnoreDependency qt -Clean
```

O padrao para toolchains portateis e: caminho explicito, `tools\<compiler>`,
`PATH` valido e bootstrap automatico. Use `-SkipToolBootstrap` para impedir
download.

## Build Cygwin, MSYS, WSL e Docker

Para Cygwin, instale pelo setup do Cygwin ao menos `gcc-core`, `make`,
`binutils` e `git` se quiser clonar o Harbour por esse ambiente. Pacotes
opcionais de headers ficam listados em `HOWTO.pt-BR.md` e `DEPENDENCIES.pt-BR.md`. O wrapper
chama o `bash.exe` do Cygwin e roda `make` dentro dele:

```powershell
.\build-cygwin.ps1 -Clean
.\build-full-cygwin.ps1 -Clean
.\build-full-cygwin.ps1 -InstallSystemDependencies -CygwinSetup C:\Users\voce\Downloads\setup-x86_64.exe -IgnoreDependency qt -Clean
```

O perfil Cygwin x64 injeta `HB_USER_CFLAGS=-march=x86-64 -mtune=generic`,
porque o `config/cygwin/gcc.mk` do Harbour ainda adiciona `-march=i586`, que o
GCC x86_64 atual rejeita.

Se o Cygwin estiver fora de `C:\cygwin64` ou `C:\cygwin`, informe o caminho:

```powershell
.\build-cygwin.ps1 -CygwinBash D:\cygwin64\bin\bash.exe -Clean
```

Para MSYS2 MSYS, instale no shell MSYS a base de build:

```bash
pacman -Syu
pacman -S --needed base-devel make binutils gcc git pkgconf
```

O Harbour nao tem `HB_PLATFORM=msys`, entao este perfil usa
`HB_PLATFORM=cygwin` com `MSYSTEM=MSYS` e `HB_BUILD_NAME=msys`, mas instala em
`out\msys`:

```powershell
.\build-msys.ps1 -Clean
.\build-full-msys.ps1 -Clean
.\build-full-msys.ps1 -InstallSystemDependencies -IgnoreDependency qt -Clean
```

Se o MSYS2 estiver fora de `C:\msys64`, informe o caminho:

```powershell
.\build-msys.ps1 -MsysBash D:\msys64\usr\bin\bash.exe -Clean
```

Para Linux via WSL, instale dentro da distro pacotes como `build-essential`,
`make`, `gcc` e `git`. Em distros Debian/Ubuntu:

```bash
sudo apt update
sudo apt install build-essential git make binutils pkg-config ca-certificates file
```

Depois rode do Windows:

```powershell
.\build-linux-wsl.ps1 -Clean
.\build-full-linux-wsl.ps1 -Clean
.\build-full-linux-wsl.ps1 -InstallSystemDependencies -IgnoreDependency qt -Clean
```

Para escolher uma distro WSL especifica:

```powershell
.\build-linux-wsl.ps1 -WslDistro Ubuntu-24.04 -Clean
```

Se sua distro exige autenticar com um usuario especifico, use `-WslUser`. O
wrapper repassa isso como `wsl.exe --user <usuario>` e aguarda o WSL retornar:

```powershell
.\build-full-linux-wsl.ps1 -WslUser seu_usuario -Clean
.\build-full-linux-wsl.ps1 -WslDistro Ubuntu-24.04 -WslUser seu_usuario -Clean
```

Os perfis `cygwin`, `msys` e `linux-wsl` usam dependencias do proprio ambiente
POSIX. O modo full nao chama o resolvedor `vcpkg` do Windows nesses perfis; ele
deixa o Makefile do Harbour detectar bibliotecas instaladas no ambiente e ativa
`HB_INSTALL_3RDDYN=yes`.

Para Linux reprodutivel, use Docker. O build normal usa
`config\docker\linux\Dockerfile`; o full usa
`config\docker\linux\Dockerfile.full`:

```powershell
.\build-linux-docker.ps1 -Clean
.\build-full-linux-docker.ps1 -Clean
```

Por padrao, o script faz `docker build` da imagem antes de executar o build.
Para reutilizar uma imagem ja criada:

```powershell
.\build-linux-docker.ps1 -SkipDockerBuild -Clean
```

Tambem e possivel trocar imagem ou Dockerfile:

```powershell
.\build-linux-docker.ps1 -DockerImage minha/imagem:dev -SkipDockerBuild -Clean
.\build-full-linux-docker.ps1 -Dockerfile config\docker\linux\Dockerfile.full -Clean
```

Quando `-IgnoreDependency qt` e usado no Docker full, o script tambem passa
`--build-arg INSTALL_QT=0` para evitar instalar os pacotes Qt na imagem.
O Docker full instala as dependencias pelo `config\docker\linux\Dockerfile.full`;
use `-SkipDockerBuild` apenas para reaproveitar uma imagem ja preparada.

Na pratica, WSL e melhor para iterar no dia a dia; Docker e melhor para
confirmar um build Linux limpo e reproduzivel.

## Build com Zig

Se o Zig ja estiver no PATH ou em `tools\zig`, nada precisa ser baixado. Para
usar um caminho especifico, informe `-ZigPath`:

```powershell
.\build-zig.ps1 -ZigPath C:\Tools\zig\zig.exe -Clean
```

Para instalar localmente em `tools\zig`:

```powershell
.\scripts\Bootstrap-Tools.ps1 -Tool Zig
```

Build nativo Windows usando Zig:

```powershell
.\build-zig.ps1 -Clean
```

Saida esperada:

```text
out\zig\bin\hbmk2.exe
out\zig\bin\harbour.exe
out\zig\lib\...
```

Perfis Zig adicionais:

```powershell
.\scripts\Invoke-HarbourBuild.ps1 -Profile zig-win64-gnu -Clean
.\scripts\Invoke-HarbourBuild.ps1 -Profile zig-win64-msvc -Clean
.\scripts\Invoke-HarbourBuild.ps1 -Profile zig-win32-gnu -Clean
.\scripts\Invoke-HarbourBuild.ps1 -Profile zig-win-arm64 -Clean
.\scripts\Invoke-HarbourBuild.ps1 -Profile zig-linux-x64 -Clean
.\scripts\Invoke-HarbourBuild.ps1 -Profile zig-linux-arm64 -Clean
```

Os perfis cross (`zig-win32-gnu`, `zig-win-arm64`, `zig-linux-*`) precisam de
um build nativo primeiro, porque o Harbour usa `hbmk2` do host durante a
compilacao:

```powershell
.\build-zig.ps1 -Clean
.\scripts\Invoke-HarbourBuild.ps1 -Profile zig-win-arm64 -Clean
```

## Dependencias opcionais

O build completo usa o comportamento padrao do Harbour: contribs ligados e
autodeteccao de bibliotecas externas quando existirem. Para configurar headers
externos:

```powershell
Copy-Item .\config\external-deps.example.ps1 .\config\external-deps.local.ps1
notepad .\config\external-deps.local.ps1
```

Para uma compilacao mais isolada, sem autodeteccao de bibliotecas externas:

```powershell
.\build-zig.ps1 -Clean -Minimal
```

Para compilar sem contribs:

```powershell
.\build-zig.ps1 -Clean -NoContrib
```

## Teste rapido do resultado

Depois de um build nativo instalado:

```powershell
.\scripts\Test-HarbourInstall.ps1 -Profile zig
```

## Build full com dependencias opcionais

Nos perfis Windows, o modo `-Full` usa `config\dependencies.json` para verificar
dependencias opcionais e, quando possivel, instala-las via `vcpkg` em
`tools\vcpkg`. Depois ele gera `config\external-deps.generated.<perfil>.ps1`
com as variaveis `HB_WITH_*` que o Harbour espera. Perfis POSIX, como `cygwin`
`msys`, `linux-wsl` e `linux-docker`, usam as dependencias instaladas dentro do
proprio ambiente.

Verificar sem instalar:

```powershell
.\scripts\Resolve-HarbourDeps.ps1 -Set full
```

Simular a preparacao completa:

```powershell
.\scripts\Resolve-HarbourDeps.ps1 -Set full -Install -GenerateEnv -DryRun
```

Instalar dependencias automatizaveis e compilar com Zig:

```powershell
.\build-full-zig.ps1 -Clean
```

Para ignorar uma dependencia especifica no build full, use
`-IgnoreDependency`. Isso tambem gera `HB_WITH_<DEP>=no`, entao o Harbour nao
tenta autodetectar a biblioteca ignorada:

```powershell
.\build-full-msvc64.ps1 -IgnoreDependency qt -Clean
.\build-full-linux-docker.ps1 -IgnoreDependency qt -Clean
.\build-full-msvc64.ps1 -IgnoreDependency qt,allegro -Clean
```

Wrappers equivalentes existem para os outros perfis comuns:

```powershell
.\build-full-msvc64.ps1 -Clean
.\build-full-mingw64.ps1 -Clean
.\build-full-standard.ps1 -Clean
.\build-full-cygwin.ps1 -Clean
.\build-full-msys.ps1 -Clean
.\build-full-linux-wsl.ps1 -Clean
.\build-full-linux-docker.ps1 -Clean
```

Somente preparar dependencias de rede:

```powershell
.\scripts\Resolve-HarbourDeps.ps1 -Set network -Install -GenerateEnv
```

Dependencias como OpenSSL, Curl, PostgreSQL/libpq, MySQL client, Qt, Cairo e
FreeImage tem caminho automatico por `vcpkg`. O ADS continua aceitando um SDK
existente via `HB_WITH_ADS`; quando ele nao for encontrado, `-Install` usa
OpenADS como fallback de codigo-fonte, clonando
`https://github.com/FiveTechSoft/OpenADS.git` em `scratch\openads` e apontando
`HB_WITH_ADS` para `scratch\openads\include\openads`.
Para executar ou linkar aplicacoes com `rddads`, use tambem a DLL/import lib do
OpenADS correspondente ao compilador/alvo (`ace64` ou `ace32`). Veja
`OPENADS.pt-BR.md` para os ajustes locais de compatibilidade e `DEPENDENCIES.pt-BR.md` para
o fluxo completo de dependencias.

Algumas outras continuam marcadas como manuais porque envolvem SDK proprietario
ou versao legada especifica que o Harbour espera, como OCILIB/Oracle, Blat e
Allegro 4.x.

Se quiser que qualquer pendencia aborte o build full:

```powershell
.\build-full-zig.ps1 -StrictDependencies
```

## Observacoes

- As saidas instaladas ficam em `out\<perfil>`.
- Os logs ficam em `logs\yyyyMMdd-HHmmss-<perfil>.log`.
- Ambientes gerados pelo resolvedor full ficam em
  `config\external-deps.generated.<perfil>.ps1` e sao ignorados pelo Git.
- Os artefatos intermediarios continuam sendo criados pelo Makefile do
  Harbour dentro do `HarbourRoot`, em `bin` e `lib`, separados por
  `HB_COMPILER`/`HB_BUILD_NAME`.
- O perfil `auto` preserva a logica existente do Harbour; o perfil `zig`
  define explicitamente `HB_PLATFORM=win` e `HB_COMPILER=zig`, como o proprio
  ChangeLog do Harbour exige.
