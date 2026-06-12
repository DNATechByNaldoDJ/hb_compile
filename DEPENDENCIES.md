# Dependencias opcionais

O modo `-Full` prepara dependencias opcionais dos contribs do Harbour antes de
chamar `win-make.exe`. A fonte da verdade fica em `config\dependencies.json`.

## Fluxo

1. O wrapper chama `scripts\Invoke-HarbourBuild.ps1` com `-Full`.
2. O executor chama `scripts\Resolve-HarbourDeps.ps1`.
3. O resolvedor procura headers ja configurados no ambiente.
4. Quando possivel, instala portas via `vcpkg` em `tools\vcpkg`.
5. O resolvedor grava `config\external-deps.generated.ps1`.
6. O build carrega primeiro o arquivo gerado e depois
   `config\external-deps.local.ps1`, permitindo override local.

## Wrappers full

```powershell
.\build-full-zig.ps1 -Clean
.\build-full-msvc64.ps1 -Clean
.\build-full-mingw64.ps1 -Clean
.\build-full-standard.ps1 -Clean
```

Triplets padrao:

- `build-full-zig.ps1`: usa o triplet padrao do catalogo, hoje `x64-windows`.
- `build-full-msvc64.ps1`: usa `x64-windows`.
- `build-full-mingw64.ps1`: usa `x64-mingw-dynamic`.
- `build-full-standard.ps1`: preserva a autodeteccao do Harbour e usa o
  triplet padrao do catalogo.

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
```

## Dependencias automatizaveis

As dependencias com caminho automatico via `vcpkg` incluem OpenSSL, libcurl,
MySQL client, PostgreSQL/libpq, Qt, Cairo e FreeImage. Algumas portas podem
falhar ou demorar conforme a revisao atual do `vcpkg`; quando isso acontece, o
resolvedor desativa a dependencia afetada e segue, exceto com
`-StrictDependencies`.

Qt usa um triplet customizado `x64-windows-no-dwm` para evitar DWM em builds do
Harbour que nao esperam essa dependencia. Em builds MinGW, confira o resultado
de `Resolve-HarbourDeps.ps1` e use override local se precisar habilitar Qt.

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

Esse arquivo nao entra no Git. Ele e carregado depois de
`external-deps.generated.ps1`, entao valores locais vencem os gerados.

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
