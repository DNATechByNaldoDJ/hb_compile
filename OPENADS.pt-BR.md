# OpenADS no build Harbour

[English](OPENADS.md) | **Português (Brasil)**

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

Nos perfis WSL e Docker, a integração é opt-in e estrita:

```powershell
.\build-full-linux-wsl.ps1 -WithOpenAds -IgnoreDependency qt
.\build-full-linux-docker.ps1 -WithOpenAds -IgnoreDependency qt
```

O runner compila o alvo CMake `openads_ace`, cria o alias Linux `libace.so`,
define `HB_WITH_ADS` e acrescenta a pasta da biblioteca a
`HB_USER_LIBPATHS`. Sem `-WithOpenAds`, o comportamento Linux não muda e
`rddads` pode ser ignorado quando nenhum SDK ADS estiver disponível.

O header usado para compilar o próprio OpenADS mantém os buffers Unicode como
`UNSIGNED16 *`. Uma cópia separada em `out\openads-<perfil>\compat` recebe a
compatibilidade `void *` exigida pelo `rddads`; assim a adaptação do Harbour não
quebra as declarações C++ do OpenADS.

Use `-OpenAdsRoot`, `-OpenAdsRepository` e `-OpenAdsRef` para controlar o
checkout. Quando a opção é solicitada, qualquer falha no checkout, CMake ou
link aborta o build, evitando um resultado que alegue conter ADS sem contê-lo.

## Ajustes locais aplicados

O Harbour atual ainda referencia algumas definicoes historicas do SDK ADS. O
OpenADS usado como fallback nao traz todas elas exatamente no mesmo formato.
O preparo reaplicavel gera um header exclusivo para o Harbour e corrige no
checkout local avisos conhecidos dos GCC atuais:

- `out\openads-<perfil>\compat\include\openads\ace.h`: adiciona os aliases
  legados `DOUBLE`, `WCHAR`, `VOID` e `ADSFIELD(n)` e adapta somente nessa
  cópia os buffers Unicode para `void *`.
- fontes C++ do OpenADS: amplia buffers usados por `snprintf`, torna explícitas
  conversões para byte e elimina uma declaração sombreada. Isso corrige os
  warnings de truncamento, conversão e shadow observados no Linux sem alterar
  o valor ou ABI produzido.
- `scratch\harbour-core\contrib\rddads\adsfunc.c`: protege a redefinicao de
  `ADS_MAX_PARAMDEF_LEN` com `#undef`, evitando warning de macro redefinida
  quando o header externo ja declara esse simbolo.
- `scratch\harbour-core\contrib\make.hb`: ao gerar bibliotecas dinamicas do
  contrib `rddads`, adiciona a biblioteca ADS correta para o alvo:
  `-lace64` em Windows x64, `-lace32` em Windows x86 e `-lace` em Linux.

Sem o ultimo ajuste, a compilacao estatica pode passar, mas o DLL do contrib
falha no link com simbolos `Ads*` indefinidos.

O CMake do OpenADS roda com `OPENADS_WARNINGS_AS_ERRORS=ON`. Assim, uma mudança
upstream que introduza novo warning interrompe o build e exige um ajuste
auditável, em vez de ocultar o diagnóstico.

## Validação Linux

Os builds full `linux-wsl` e `linux-docker`, com Qt ignorado, foram validados
com OpenADS e HBDAP habilitados simultaneamente. Ambos instalaram `hbmk2`,
`librddads.a` e `libhbdap.a`; o OpenADS produziu `libopenace64.so` e o alias
`libace.so`. O smoke test funcional de operações ADS permanece como etapa
separada no TODO.

O sample `hello.prg` também foi compilado e executado nos perfis MinGW64,
MSVC64, Cygwin, MSYS, WSL, Docker e Zig. Para testar uma instalação produzida
pelo build full Docker, selecione explicitamente sua imagem:

```powershell
pwsh ./scripts/Test-HarbourBuilds.ps1 -Profile linux-docker `
  -DockerImage hb-compile/linux:full
```

A imagem `hb-compile/linux:base` não deve executar binários gerados contra as
dependências adicionais da imagem full.

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
