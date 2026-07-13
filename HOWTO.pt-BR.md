# HOWTO: processo de build

[English](HOWTO.md) | **Português (Brasil)**

Este documento centraliza o fluxo de construcao do Harbour neste repositorio.
Ele descreve o que cada wrapper faz, onde configurar os perfis e como
diagnosticar falhas sem precisar ler todos os scripts.

## Visao geral

O projeto compila um checkout local do Harbour. Por padrao, se o fonte ainda
nao existir, `scripts\Invoke-HarbourBuild.ps1` clona:

```text
https://github.com/harbour/core.git
```

em:

```text
scratch\harbour-core
```

As instalacoes ficam em `out\<perfil>`, os logs completos ficam em `logs\`, as
ferramentas baixadas ficam em `tools\` e arquivos temporarios ficam em
`scratch\`.

O executor principal e:

```powershell
.\scripts\Invoke-HarbourBuild.ps1
```

Os arquivos `build-*.ps1` e `build-*.cmd` sao apenas atalhos para esse executor
com um perfil ja escolhido.

## Build normal e build full

O build normal compila e instala o Harbour usando as dependencias que o
Makefile detectar naturalmente no ambiente.

Exemplo:

```powershell
.\build-mingw64.ps1 -Clean
```

O build full passa `-Full` para o executor. Em perfis Windows, isso roda o
resolvedor de dependencias opcionais e pode instalar bibliotecas via `vcpkg`.
Em perfis POSIX, como Cygwin, MSYS, WSL e Docker, o full usa as bibliotecas ja
instaladas dentro do proprio ambiente.

Exemplo:

```powershell
.\build-full-mingw64.ps1 -Clean
```

## Perfis disponiveis

| Perfil | Wrapper normal | Wrapper full | Ambiente |
| --- | --- | --- | --- |
| `auto` | `build-standard.ps1` | `build-full-standard.ps1` | `win-make.exe` com autodeteccao do Harbour |
| `mingw64` | `build-mingw64.ps1` | `build-full-mingw64.ps1` | MinGW-w64 por `-MinGwPath`, `tools\mingw64` ou `PATH` |
| `msvc64` | `build-msvc64.ps1` | `build-full-msvc64.ps1` | Visual Studio C++ Build Tools |
| `zig` | `build-zig.ps1` | `build-full-zig.ps1` | Zig |
| `cygwin` | `build-cygwin.ps1` | `build-full-cygwin.ps1` | Cygwin `bash`, `make` e `gcc` |
| `msys` | `build-msys.ps1` | `build-full-msys.ps1` | MSYS2 MSYS `bash`, `make` e `gcc` |
| `linux-wsl` | `build-linux-wsl.ps1` | `build-full-linux-wsl.ps1` | WSL Linux |
| `linux-docker` | `build-linux-docker.ps1` | `build-full-linux-docker.ps1` | Docker Linux |

Tambem existem perfis Zig adicionais para cross-build. Liste todos com:

```powershell
.\scripts\Invoke-HarbourBuild.ps1 -ListProfiles
```

## Comandos principais

Ver status do ambiente:

```powershell
.\scripts\Show-Status.ps1
```

Ver o comando sem compilar:

```powershell
.\build-cygwin.ps1 -DryRun
```

Executar build limpo:

```powershell
.\build-cygwin.ps1 -Clean
```

Executar full ignorando Qt:

```powershell
.\build-full-msvc64.ps1 -IgnoreDependency qt -Clean
.\build-full-linux-docker.ps1 -IgnoreDependency qt -Clean
```

O parametro `-IgnoreDependency` tambem aceita lista:

```powershell
.\build-full-mingw64.ps1 -IgnoreDependency qt,allegro -Clean
```

Quando uma dependencia ignorada tem contribs diretamente associados, o wrapper
tambem pode exclui-los do build. Hoje `qt` adiciona `HB_BUILD_CONTRIBS=no gtqtc`
para impedir que o plugin Qt procure `moc`.

## Padrao de toolchains

Toolchains e ambientes de build seguem sempre a mesma prioridade:

1. Caminho informado por parametro, como `-ZigPath`, `-MinGwPath`,
   `-CygwinPath` ou `-MsysPath`.
2. Ferramenta ja baixada em `tools\<compiler>`.
3. Ferramenta ja disponivel no `PATH`.
4. Bootstrap automatico por `scripts\Bootstrap-Tools.ps1`, salvo quando
   `-SkipToolBootstrap` for usado.

Exemplos:

```powershell
.\build-zig.ps1 -ZigPath C:\Tools\zig\zig.exe -Clean
.\build-full-mingw64.ps1 -MinGwPath C:\Tools\xpack-mingw-w64-gcc\bin -IgnoreDependency qt -Clean
.\build-cygwin.ps1 -CygwinPath D:\cygwin64 -Clean
.\build-msys.ps1 -MsysPath E:\msys64 -Clean
```

Se nenhum caminho for informado, os builds procuram primeiro em:

```text
tools\zig\...\zig.exe
tools\mingw64\...\bin\gcc.exe
tools\cygwin\bin\bash.exe
tools\msys\...\usr\bin\bash.exe
```

Se ainda nao houver ferramenta valida, o executor baixa automaticamente:

```powershell
.\scripts\Bootstrap-Tools.ps1 -Tool Zig
.\scripts\Bootstrap-Tools.ps1 -Tool MinGW64
.\scripts\Bootstrap-Tools.ps1 -Tool Cygwin
.\scripts\Bootstrap-Tools.ps1 -Tool MSYS
.\scripts\Bootstrap-Tools.ps1 -Tool All
```

Use `-SkipToolBootstrap` para validar apenas o ambiente atual, sem download.

MSVC, Cygwin, MSYS, WSL e Docker nao seguem esse modelo de zip portatil:
MSVC vem do Visual Studio Build Tools; Cygwin/MSYS usam `-CygwinBash` e
`-MsysBash`; WSL usa a distro Linux; Docker usa a imagem configurada pelo
Dockerfile.

## Dependencias de sistema no full

Nos perfis POSIX (`cygwin`, `msys`, `linux-wsl` e `linux-docker`), o modo full
nao usa `vcpkg`. Ele depende dos pacotes instalados no proprio ambiente.

Para instalar os pacotes conhecidos automaticamente antes do build, use:

```powershell
.\build-full-msys.ps1 -InstallSystemDependencies -IgnoreDependency qt -Clean
.\build-full-linux-wsl.ps1 -InstallSystemDependencies -IgnoreDependency qt -Clean
.\build-full-cygwin.ps1 -InstallSystemDependencies -CygwinSetup C:\Users\voce\Downloads\setup-x86_64.exe -IgnoreDependency qt -Clean
```

`-InstallSystemDependencies` respeita `-DependencySet`, `-Dependency` e
`-IgnoreDependency`. Dependencias sem pacote confiavel no ambiente continuam
manuais; exemplos comuns sao ADS, Blat e OCILIB/Oracle. Em MSYS, o repositorio
MSYS tambem nao oferece varias bibliotecas pesadas de GUI/banco, entao elas
podem continuar sendo puladas pelo `hbmk2`.

Para ver o comando sem instalar:

```powershell
.\build-full-msys.ps1 -InstallSystemDependencies -DryRun
```

Para impedir qualquer instalacao automatica no full:

```powershell
.\build-full-msys.ps1 -SkipDependencyInstall
```

## Configuracao

A fonte da verdade dos perfis fica em:

```text
config\profiles.json
```

Esse arquivo define `HB_PLATFORM`, `HB_COMPILER`, pasta de instalacao, runner e
variaveis de ambiente especificas de cada perfil.

O catalogo de dependencias opcionais do modo full fica em:

```text
config\dependencies.json
```

O resolvedor Windows gera arquivos como:

```text
config\external-deps.generated.<perfil>.ps1
```

Para ajustes locais, copie:

```powershell
Copy-Item .\config\external-deps.example.ps1 .\config\external-deps.local.ps1
```

O arquivo local e ignorado pelo Git.

## Cygwin

Instale no Cygwin pelo setup oficial pelo menos:

```text
gcc-core
make
binutils
git
pkg-config
```

Para reduzir contribs desativados por falta de headers no build normal/full,
tambem vale instalar estes pacotes de desenvolvimento quando forem relevantes
para a rodada:

```text
zlib-devel
libpcre-devel
libncurses-devel
libslang-devel
libX11-devel
libsqlite3-devel
libbz2-devel
libexpat-devel
unixODBC-devel
libcups-devel
libcurl-devel
openssl-devel
libpq-devel
libmariadb-devel
libcairo-devel
libfreeimage-devel
libgd-devel
libmagic-devel
ghostscript
libgs-devel
```

Exemplo via setup do Cygwin:

```powershell
C:\Users\voce\Downloads\setup-x86_64.exe --quiet-mode --root C:\cygwin64 --packages gcc-core,make,binutils,git,pkg-config,zlib-devel,libpcre-devel,libncurses-devel,libslang-devel,libX11-devel,libsqlite3-devel,libbz2-devel,libexpat-devel,unixODBC-devel,libcups-devel,openssl-devel,libcurl-devel,libmariadb-devel,libpq-devel,libcairo-devel,libfreeimage-devel,libgd-devel,libmagic-devel,ghostscript,libgs-devel
```

Qt e Allegro sao casos mais pesados/legados. Para validar o full sem Qt, use
`-IgnoreDependency qt`; para Allegro, o contrib do Harbour espera Allegro 4.x.

Validacao rapida do ambiente:

```powershell
C:\cygwin64\bin\bash.exe -lc "command -v make gcc git ar ld; gcc -dumpmachine"
```

Comandos:

```powershell
.\build-cygwin.ps1 -Clean
.\build-full-cygwin.ps1 -IgnoreDependency qt -Clean
```

Se o Cygwin estiver fora de `C:\cygwin64` ou `C:\cygwin`, informe o `bash.exe`:

```powershell
.\build-cygwin.ps1 -CygwinBash D:\cygwin64\bin\bash.exe -Clean
```

O perfil Cygwin usa `HB_PLATFORM=cygwin` e `HB_COMPILER=gcc`. Ele tambem define
`HB_BUILD_DYN=no`, `HB_BUILD_SHARED=no` e `HB_BUILD_CONTRIB_DYN=no` para evitar
as etapas de DLL que sao frageis no Harbour atual em Cygwin.

## MSYS2 MSYS

Instale no MSYS2, no ambiente MSYS, pelo menos:

```bash
pacman -Syu
pacman -S --needed base-devel make binutils gcc git pkgconf
```

`base-devel` ja traz ferramentas como `make` e `binutils`, mas eles ficam
explicitos no comando para resolver direto erros como `Ferramenta 'make' nao
foi encontrada`. O `gcc` MSYS e instalado separadamente.

Para aumentar a cobertura do build full, instale tambem os headers das
bibliotecas opcionais que deseja testar:

```bash
pacman -S --needed zlib-devel pcre-devel ncurses-devel libsqlite-devel libcurl-devel openssl-devel
```

O repositorio MSYS e menor que os ambientes MinGW/WSL/Docker. Dependencias como
PostgreSQL/libpq, MariaDB/MySQL, X11, Cairo, GD, FreeImage, Firebird,
Oracle/OCILIB, Ghostscript, Allegro e Qt normalmente continuam manuais ou sao
melhor testadas em Docker/WSL/MinGW.

Validacao rapida do ambiente:

```powershell
e:\msys64\usr\bin\bash.exe -lc "command -v make gcc git ar ld; gcc -dumpmachine; echo MSYSTEM=$MSYSTEM"
```

Comandos:

```powershell
.\build-msys.ps1 -Clean
.\build-full-msys.ps1 -IgnoreDependency qt -Clean
```

Se o MSYS2 estiver fora de `C:\msys64`, informe o `bash.exe`:

```powershell
.\build-msys.ps1 -MsysBash D:\msys64\usr\bin\bash.exe -Clean
```

O Harbour nao possui um `HB_PLATFORM=msys` separado. Por isso o perfil `msys`
usa `HB_PLATFORM=cygwin` com `MSYSTEM=MSYS`. O perfil tambem define
`HB_BUILD_NAME=msys` e instala em `out\msys`, mantendo os artefatos MSYS
separados dos artefatos Cygwin.

## MinGW-w64/MSYS2

O perfil `mingw64` e diferente do perfil `msys`: ele usa o build Windows do
Harbour com `HB_PLATFORM=win` e `HB_COMPILER=mingw64`.

Use este perfil quando tiver um GCC MinGW-w64 valido por `-MinGwPath`,
`tools\mingw64` ou `PATH`:

```powershell
.\build-mingw64.ps1 -Clean
.\build-full-mingw64.ps1 -IgnoreDependency qt -Clean
```

Para usar uma instalacao local especifica:

```powershell
.\build-full-mingw64.ps1 -MinGwPath F:\MinGW64\xpack-mingw-w64-gcc\bin -IgnoreDependency qt -Clean
```

`-MinGwPath` pode apontar para a pasta raiz do toolchain ou para a pasta
`bin`. Ela precisa conter um `gcc.exe` funcional cujo `gcc -dumpmachine` indique
MinGW-w64. A pasta de fontes `mingw-w64-v6.0.1`, sozinha, nao e um compilador
pronto.

Se nada for informado e `tools\mingw64` ainda nao existir, o wrapper baixa um
toolchain portatil xPack MinGW-w64 GCC para essa pasta. Se o primeiro
`gcc.exe` no `PATH` for do Cygwin e o bootstrap estiver desativado, o wrapper
falha cedo para evitar misturar toolchains.

O xPack usa executaveis prefixados, como `x86_64-w64-mingw32-gcc.exe`. O
wrapper detecta esse layout e passa `HB_CCPATH`/`HB_CCPREFIX` ao Harbour, entao
nao e necessario criar `gcc.exe` manualmente.

## Windows Sandbox

Consulte [BUILD-SANDBOX.pt-BR.md](BUILD-SANDBOX.pt-BR.md) para a especificação
completa, persistência, saída limpa, timeouts e limitações conhecidas.

O launcher `build-sandbox.ps1` valida os toolchains portateis em uma instalacao
limpa do Windows. A primeira versao suporta `zig`, todas as variantes Zig
declaradas em `config\profiles.json`, e `mingw64`:

```powershell
.\build-sandbox.ps1 -BuildProfile zig -Clean
.\build-sandbox.ps1 -BuildProfile mingw64 -Full -IgnoreDependency qt -Clean
.\build-sandbox.ps1 -BuildProfile zig-linux-x64 -Clean
```

O recurso opcional Windows Sandbox precisa estar habilitado. O launcher cria
um snapshot temporario dos scripts e o copia para `C:\hb_compile` dentro da VM.
Somente `scratch`, `tools`, `logs` e `out` sao mapeados com persistencia. Com
isso, downloads e o checkout do Harbour sao reutilizados, enquanto a camada de
build do host nao e modificada pelo convidado. Os mapeamentos nao se sobrepoem,
uma exigencia importante para a inicializacao confiavel do Sandbox.

Por padrao, a VM recebe 8192 MB e acesso a rede. Use `-MemoryInMB`,
`-NoNetworking`, `-DryRun`, `-KeepOpen` ou `-KeepSession` conforme necessario.
`-SandboxTimeoutMinutes` controla por quanto tempo o host aguarda o
`result.json` (240 minutos por padrao). O launcher detecta uma instancia ativa
antes de iniciar, pois o Windows Sandbox permite apenas uma VM por vez.
`-NoNetworking` so funciona quando todos os fontes e toolchains exigidos ja
estao nos diretorios persistentes.

Perfis `cygwin` e `msys` ficam para uma etapa posterior, pois exigem
provisionamento de pacotes do ambiente POSIX. `auto` nao e reproduzivel;
`msvc64` depende de uma instalacao integrada do Visual Studio Build Tools.
WSL e Docker ficam deliberadamente fora deste launcher.

Se o build falhar ou o Sandbox for fechado manualmente, a sessao e mantida em
`%TEMP%\hb_compile-sandbox\<data-hora>`, incluindo o `.wsb`, a requisicao, o
`sandbox.log` e o resultado. Ao encerrar a VM, o launcher aguarda a sincronizacao
da pasta mapeada antes de ler o resultado.
Sessoes bem-sucedidas sao removidas, exceto com `-KeepSession`.

## WSL e Docker

WSL usa a distro Linux instalada na maquina:

```bash
sudo apt update
sudo apt install build-essential git make binutils pkg-config ca-certificates file
```

Para uma rodada full com mais contribs detectados em Debian/Ubuntu, instale os
headers opcionais que fizerem sentido:

```bash
sudo apt install zlib1g-dev libpcre3-dev libncurses-dev libslang2-dev libx11-dev libssl-dev libcurl4-openssl-dev libpq-dev default-libmysqlclient-dev libsqlite3-dev libbz2-dev libexpat1-dev firebird-dev libcairo2-dev libfreeimage-dev libgd-dev libmagic-dev ghostscript libgs-dev libcups2-dev unixodbc-dev liballegro4-dev
```

Se quiser testar Qt no WSL, acrescente:

```bash
sudo apt install qt6-base-dev qt6-base-dev-tools
```

```powershell
.\build-linux-wsl.ps1 -Clean
.\build-full-linux-wsl.ps1 -IgnoreDependency qt -Clean
```

Para escolher distro e usuario:

```powershell
.\build-full-linux-wsl.ps1 -WslDistro Ubuntu-24.04 -WslUser seu_usuario -Clean
```

Docker usa os Dockerfiles em `config\docker\linux\`:

```powershell
.\build-linux-docker.ps1 -Clean
.\build-full-linux-docker.ps1 -IgnoreDependency qt -Clean
```

Quando `-IgnoreDependency qt` e usado no Docker full, o executor tambem passa
`INSTALL_QT=0` para o `docker build`.

O `build-full-linux-docker.ps1` usa `config\docker\linux\Dockerfile.full`, que
instala a base de build e os headers opcionais via `apt-get`. Para forcar uma
reconstrucao da imagem, use:

```powershell
.\build-full-linux-docker.ps1 -DockerBuildArg '--no-cache' -IgnoreDependency qt -Clean
```

## Saidas e logs

Cada build imprime no inicio:

```text
HarbourRoot
Perfil
Runner
Install
Log
Comando
Ambiente Harbour
```

Se falhar, abra o log indicado em `logs\yyyyMMdd-HHmmss-<perfil>.log`.

Depois de um build nativo instalado, compile o sample:

```powershell
.\scripts\Test-HarbourInstall.ps1 -Profile zig
```

Para Cygwin/MSYS, o `hbmk2` gerado pode depender das DLLs do proprio ambiente.
Nesse caso, rode o teste dentro do shell correspondente ou garanta que as DLLs
estejam no `PATH`.

## Troubleshooting rapido

- `win-make.exe nao encontrado`: confirme `HarbourRoot` ou deixe o executor
  clonar `scratch\harbour-core`.
- `gcc do Cygwin` no perfil `mingw64`: use `build-cygwin.ps1` ou ajuste o
  `PATH` para apontar primeiro para MinGW-w64.
- `bash.exe do Cygwin nao foi encontrado`: use `-CygwinBash`.
- `bash.exe do MSYS2 nao foi encontrado`: use `-MsysBash`.
- Qt demorando muito no full: use `-IgnoreDependency qt`.
- Dependencia opcional ausente em POSIX: instale pelo gerenciador do ambiente
  Cygwin/MSYS/WSL ou ignore a dependencia no full.
- Cygwin/MSYS tentando montar DLLs do core ou contribs: confirme que o perfil
  esta usando `HB_BUILD_DYN=no`, `HB_BUILD_SHARED=no` e
  `HB_BUILD_CONTRIB_DYN=no`.
