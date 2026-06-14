# HOWTO: processo de build

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
| `mingw64` | `build-mingw64.ps1` | `build-full-mingw64.ps1` | MinGW-w64/MSYS2 no `PATH` |
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

Use este perfil quando o `gcc.exe` no `PATH` vier do ambiente MinGW-w64/MSYS2:

```powershell
.\build-mingw64.ps1 -Clean
.\build-full-mingw64.ps1 -IgnoreDependency qt -Clean
```

Se o primeiro `gcc.exe` no `PATH` for do Cygwin, o wrapper falha cedo para
evitar misturar toolchains.

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
