# Dependencias opcionais

O modo `-Full` prepara dependencias opcionais dos contribs do Harbour. Em
perfis Windows ele chama `win-make.exe` e usa `vcpkg`; em perfis POSIX, como
`cygwin`, `msys`, `linux-wsl` e `linux-docker`, ele usa as bibliotecas ja
instaladas no ambiente correspondente. A fonte da verdade para o resolvedor Windows fica em
`config\dependencies.json`.

## Fluxo

1. O wrapper chama `scripts\Invoke-HarbourBuild.ps1` com `-Full`.
2. O executor chama `scripts\Resolve-HarbourDeps.ps1`.
3. O resolvedor procura headers ja configurados no ambiente.
4. Quando possivel, instala portas via `vcpkg` em `tools\vcpkg`.
5. O resolvedor grava `config\external-deps.generated.<perfil>.ps1`.
6. O build carrega primeiro o arquivo gerado e depois
   `config\external-deps.local.ps1`, permitindo override local.

Nos perfis `cygwin`, `msys`, `linux-wsl` e `linux-docker`, o fluxo pula o
resolvedor `vcpkg` do Windows e nao carrega `external-deps.local.ps1`, para
evitar misturar paths Windows com paths POSIX. Instale as dependencias opcionais
diretamente no Cygwin/MSYS/WSL, ou ajuste `config\docker\linux\Dockerfile.full`
no caso Docker, quando quiser que o Makefile do Harbour as detecte.

## Pacotes por ambiente

O build full de perfis POSIX usa pacotes do proprio ambiente. Para tentar
instalar automaticamente os pacotes conhecidos antes do build:

```powershell
.\build-full-cygwin.ps1 -InstallSystemDependencies -CygwinSetup C:\Users\voce\Downloads\setup-x86_64.exe -IgnoreDependency qt -Clean
.\build-full-msys.ps1 -InstallSystemDependencies -IgnoreDependency qt -Clean
.\build-full-linux-wsl.ps1 -InstallSystemDependencies -IgnoreDependency qt -Clean
```

Use `-SkipDependencyInstall` para impedir qualquer instalacao automatica.

Base Cygwin:

```text
gcc-core
make
binutils
git
pkg-config
```

Pacotes Cygwin uteis para ampliar o build full:

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

Base MSYS2 MSYS:

```bash
pacman -Syu
pacman -S --needed base-devel make binutils gcc git pkgconf
```

Pacotes MSYS2 MSYS uteis para ampliar o build full:

```bash
pacman -S --needed zlib-devel pcre-devel ncurses-devel libsqlite-devel libcurl-devel openssl-devel
```

O repositorio MSYS e limitado; PostgreSQL/libpq, MariaDB/MySQL, X11, Cairo, GD,
FreeImage, Firebird, Oracle/OCILIB, Ghostscript, Allegro e Qt normalmente sao
melhor cobertos em WSL, Docker, Cygwin ou MinGW.

Base WSL Debian/Ubuntu:

```bash
sudo apt update
sudo apt install build-essential git make binutils pkg-config ca-certificates file
```

Pacotes Debian/Ubuntu uteis para ampliar o build full:

```bash
sudo apt install zlib1g-dev libpcre3-dev libncurses-dev libslang2-dev libx11-dev libssl-dev libcurl4-openssl-dev libpq-dev default-libmysqlclient-dev libsqlite3-dev libbz2-dev libexpat1-dev firebird-dev libcairo2-dev libfreeimage-dev libgd-dev libmagic-dev ghostscript libgs-dev libcups2-dev unixodbc-dev liballegro4-dev
```

Para testar Qt no WSL/Debian/Ubuntu:

```bash
sudo apt install qt6-base-dev qt6-base-dev-tools
```

Docker full usa `config\docker\linux\Dockerfile.full`, que instala a base e os
headers opcionais durante o `docker build`. Use `-SkipDockerBuild` apenas quando
quiser reaproveitar uma imagem ja preparada.

Para Windows nativo, os perfis `standard`, `mingw64`, `msvc64` e `zig` usam o
resolvedor `vcpkg` quando possivel. Ainda assim, SDKs proprietarios ou legados,
como ADS, Oracle/OCILIB, Firebird client, Ghostscript e Allegro 4.x, podem
exigir instalacao manual e variaveis `HB_WITH_*`.

## Wrappers full

```powershell
.\build-full-zig.ps1 -Clean
.\build-full-msvc64.ps1 -Clean
.\build-full-mingw64.ps1 -Clean
.\build-full-standard.ps1 -Clean
.\build-full-cygwin.ps1 -Clean
.\build-full-msys.ps1 -Clean
.\build-full-linux-wsl.ps1 -Clean
.\build-full-linux-docker.ps1 -Clean
```

Triplets padrao:

- `build-full-zig.ps1`: usa o triplet padrao do catalogo, hoje `x64-windows`.
- `build-full-msvc64.ps1`: usa `x64-windows`.
- `build-full-mingw64.ps1`: usa `x64-mingw-dynamic`.
- `build-full-standard.ps1`: preserva a autodeteccao do Harbour e usa o
  triplet padrao do catalogo.
- `build-full-cygwin.ps1`, `build-full-msys.ps1`, `build-full-linux-wsl.ps1` e
  `build-full-linux-docker.ps1`: nao usam triplet `vcpkg`; dependem dos
  pacotes instalados no ambiente POSIX.

Qualquer wrapper aceita override:

```powershell
.\build-full-mingw64.ps1 -DependencyTriplet x64-mingw-static -Clean
```

Quando uma variavel `HB_WITH_*` ja aponta para outro triplet dentro de
`tools\vcpkg\installed`, o resolvedor ignora esse path para evitar mistura entre
perfis. Caminhos manuais fora do vcpkg local continuam tendo precedencia.

## Conjuntos

Os conjuntos disponiveis sao:

- `full`: rede, bancos, GUI, graficos e dependencias especiais.
- `network`: OpenSSL e libcurl.
- `database`: MySQL, PostgreSQL/libpq, Firebird, ADS e OCILIB.
- `gui`: Qt e Allegro.
- `graphics`: Cairo, FreeImage, GD e Ghostscript.

Exemplos:

```powershell
.\scripts\Resolve-HarbourDeps.ps1 -Set database -Install -GenerateEnv
.\build-full-zig.ps1 -DependencySet network -Clean
.\build-full-zig.ps1 -Dependency openssl,curl,ads -Clean
.\build-full-msvc64.ps1 -IgnoreDependency qt -Clean
```

`-IgnoreDependency` aceita uma ou mais dependencias e gera `HB_WITH_*=no` para
elas, evitando tanto instalacao quanto autodeteccao pelo Makefile do Harbour.
Use isso para dependencias demoradas ou indesejadas em uma rodada de validacao,
por exemplo `-IgnoreDependency qt`. Quando a dependencia tem contribs
diretamente associados, o executor tambem pode exclui-los; hoje `qt` acrescenta
`HB_BUILD_CONTRIBS=no gtqtc` para evitar a inicializacao do plugin Qt.

## Dependencias automatizaveis

As dependencias com caminho automatico via `vcpkg` incluem OpenSSL, libcurl,
MySQL client, PostgreSQL/libpq, Qt, Cairo e FreeImage. Algumas portas podem
falhar ou demorar conforme a revisao atual do `vcpkg`; quando isso acontece, o
resolvedor desativa a dependencia afetada e segue, exceto com
`-StrictDependencies`.

Qt usa um triplet customizado `x64-windows-no-dwm` nos builds MSVC para evitar
DWM em builds do Harbour que nao esperam essa dependencia. Em builds MinGW, o
resolvedor usa `x64-mingw-dynamic` por padrao. Algumas portas do vcpkg, como
`libmysql` e `libmagic`, sao marcadas como nao suportadas em MinGW e sao
desativadas automaticamente quando nao houver override manual.

O wrapper `build-full-mingw64.ps1` tambem valida o toolchain antes de resolver
dependencias: `gcc -dumpmachine` precisa apontar para MinGW-w64/MSYS2. A
prioridade e `-MinGwPath`, `tools\mingw64`, `PATH` valido e bootstrap
automatico via `scripts\Bootstrap-Tools.ps1 -Tool MinGW64`. Se quiser apenas
validar o ambiente atual, use `-SkipToolBootstrap`. Se o `gcc.exe` encontrado
for o do Cygwin e o bootstrap estiver desativado, use `build-full-cygwin.ps1`
ou informe um MinGW-w64 real com `-MinGwPath`.

## Dependencias manuais

Algumas dependencias continuam manuais porque dependem de SDK proprietario,
cliente oficial ou versao historica especifica:

- ADS: usa OpenADS como fallback; detalhes em `OPENADS.md`.
- Firebird: pode exigir o client oficial para obter `fbclient`.
- Ghostscript: precisa de headers e DLL/binario configurados.
- Allegro: o contrib espera Allegro 4.x, nao Allegro 5.
- Blat: espera o fonte/header compativel.
- OCILIB/Oracle: normalmente depende tambem do Oracle Client ou Instant Client.
- GD/libmagic: podem exigir revisao manual do nome de biblioteca esperado pelo
  contrib do Harbour.

## Overrides locais

Use `config\external-deps.local.ps1` para ajustes da maquina:

```powershell
$env:HB_WITH_ADS = 'F:\SDKs\OpenADS\include\openads'
$env:HB_WITH_MYSQL = 'F:\SDKs\mysql\include'
$env:HB_USER_LIBPATHS = 'F:\SDKs\OpenADS\dist\import-libs\x64\msvc'
```

Esse arquivo nao entra no Git. Em perfis Windows, ele e carregado depois de
`external-deps.generated.<perfil>.ps1`, entao valores locais vencem os gerados.

## Diagnostico rapido

Para ver o plano sem instalar nada:

```powershell
.\scripts\Resolve-HarbourDeps.ps1 -Set full
```

Para simular instalacao e geracao do ambiente:

```powershell
.\scripts\Resolve-HarbourDeps.ps1 -Set full -Install -GenerateEnv -DryRun
```

Para abortar o build quando qualquer dependencia ficar pendente:

```powershell
.\build-full-zig.ps1 -StrictDependencies
```

Os logs ficam em `logs\`. Os artefatos instalados ficam em `out\<perfil>`.
