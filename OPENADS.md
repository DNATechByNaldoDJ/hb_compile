# OpenADS no build Harbour

Este projeto usa OpenADS como fallback local para habilitar o contrib
`rddads` quando o SDK original do Advantage Database Server nao esta
disponivel.

## Quando ele entra no build

O resolvedor de dependencias consulta `config\dependencies.json`. Para ADS,
ele procura primeiro um SDK existente via `HB_WITH_ADS`. Se nao encontrar e o
build estiver em modo `-Full` com instalacao de dependencias habilitada, ele
clona o fallback:

```text
https://github.com/FiveTechSoft/OpenADS.git
```

em:

```text
scratch\openads
```

e gera:

```powershell
$env:HB_WITH_ADS = '<repo>\scratch\openads\include\openads'
```

no arquivo `config\external-deps.generated.ps1`.

## Ajustes locais aplicados

O Harbour atual ainda referencia algumas definicoes historicas do SDK ADS. O
OpenADS usado como fallback nao traz todas elas exatamente no mesmo formato, por
isso este checkout usa quatro ajustes locais:

- `scratch\openads\include\openads\ace.h`: adiciona `ADSFIELD(n)` quando a
  macro nao existir. Ela converte identificador numerico de campo para o tipo
  `UNSIGNED8 *` esperado pelas chamadas antigas do ADS.
- `scratch\openads\include\openads\ace.h`: normaliza os buffers das chamadas
  Unicode `AdsSetStringW`, `AdsGetStringW` e `AdsGetFieldW` como `void *`. No
  MSVC, isso evita erro entre `WCHAR *` e `UNSIGNED16 *`; o ABI continua sendo
  apenas ponteiro para dados UTF-16LE.
- `scratch\harbour-core\contrib\rddads\adsfunc.c`: protege a redefinicao de
  `ADS_MAX_PARAMDEF_LEN` com `#undef`, evitando warning de macro redefinida
  quando o header externo ja declara esse simbolo.
- `scratch\harbour-core\contrib\make.hb`: ao gerar bibliotecas dinamicas do
  contrib `rddads`, adiciona a biblioteca ADS correta para o alvo:
  `-lace64` em Windows x64, `-lace32` em Windows x86 e `-lace` em Linux.

Sem o ultimo ajuste, a compilacao estatica pode passar, mas o DLL do contrib
falha no link com simbolos `Ads*` indefinidos.

## Bibliotecas de link

O OpenADS inclui DLLs e import libs precompiladas em `scratch\openads\dist`.
O arquivo local `config\external-deps.local.ps1` pode adicionar esses caminhos
em `HB_USER_LIBPATHS`, por exemplo:

```powershell
$adsLibPaths = @(
   'scratch\openads\dist\import-libs\x64\msvc',
   'scratch\openads\dist\import-libs\x64\mingw',
   'scratch\openads\dist\import-libs\x86\msvc',
   'scratch\openads\dist\import-libs\x86\mingw'
)
```

Esse arquivo e propositalmente local e ignorado pelo Git, porque pode variar
conforme o compilador, arquitetura e SDK instalado na maquina.

## Como validar

Para validar sem reinstalar dependencias:

```powershell
.\build-full-zig.ps1 -SkipDependencyInstall
```

No log, procure uma linha parecida com:

```text
rddads/rddads.hbp @hbpost rddads/rddads.hbc -lace64
```

Tambem e esperado encontrar o DLL instalado, por exemplo:

```text
out\zig\bin\rddads-32-x64.dll
```

## Solucao de problemas

Se aparecer erro ou warning envolvendo `ADSFIELD`, confira se o header em
`scratch\openads\include\openads\ace.h` contem a macro de compatibilidade.

Se aparecerem simbolos `Ads*` indefinidos ao gerar `rddads-*.dll`, confira se
o ajuste em `contrib\make.hb` esta ativo e se `HB_USER_LIBPATHS` contem a pasta
da import lib `ace64`, `ace32` ou `ace`.

Em tempo de execucao, a DLL correspondente (`ace64.dll`, `ace32.dll` ou
equivalente do alvo) tambem precisa estar no `PATH` ou ao lado do executavel.

OpenADS e um fallback aberto. Se voce tiver o SDK oficial do ADS, pode apontar
`HB_WITH_ADS` para ele em `config\external-deps.local.ps1`; essa configuracao
local tem precedencia sobre a gerada automaticamente.
