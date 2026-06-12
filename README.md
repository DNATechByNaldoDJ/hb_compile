# hb_compile

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
- `config\external-deps.example.ps1`: modelo para dependencias opcionais `HB_WITH_*`.
- `scripts\Invoke-HarbourBuild.ps1`: executor principal.
- `scripts\Bootstrap-Tools.ps1`: baixa ferramentas locais, hoje focado em Zig.
- `scripts\Show-Status.ps1`: mostra HarbourRoot, Zig, win-make e saidas.
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

O perfil `msvc64` tenta carregar automaticamente o ambiente do Visual Studio
Build Tools via `vswhere`. Se preferir, abra antes um "Developer PowerShell"
ou chame `vcvarsall.bat` e use `-NoVsDevShell`.

## Build com Zig

Se o Zig ja estiver no PATH, nada precisa ser baixado. Para instalar localmente
em `tools\zig`:

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

O modo `-Full` usa `config\dependencies.json` para verificar dependencias
opcionais e, quando possivel, instala-las via `vcpkg` em `tools\vcpkg`.
Depois ele gera `config\external-deps.generated.ps1` com as variaveis
`HB_WITH_*` que o Harbour espera.

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
OpenADS correspondente ao compilador/alvo (`ace64` ou `ace32`).

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
- Os artefatos intermediarios continuam sendo criados pelo Makefile do
  Harbour dentro do `HarbourRoot`, em `bin` e `lib`, separados por
  `HB_COMPILER`/`HB_BUILD_NAME`.
- O perfil `auto` preserva a logica existente do Harbour; o perfil `zig`
  define explicitamente `HB_PLATFORM=win` e `HB_COMPILER=zig`, como o proprio
  ChangeLog do Harbour exige.
