# Builds com Windows Sandbox

[English](BUILD-SANDBOX.md) | **Português (Brasil)**

O `build-sandbox.ps1` executa perfis selecionados do Harbour em um Windows
Sandbox descartável, mantendo fontes baixadas, toolchains, logs e instalações
no host.

## Objetivo e uso recomendado

O fluxo do Sandbox é principalmente uma ferramenta de **validação em ambiente
limpo**. Seu objetivo é confirmar que um perfil consegue preparar suas
ferramentas e compilar em um Windows novo, sem depender silenciosamente de
programas, variáveis de ambiente, entradas de registro ou configurações da
estação do desenvolvedor.

Ele não foi projetado como o caminho principal de build no dia a dia. A
inicialização do Sandbox, a cópia do snapshot, o provisionamento de ferramentas,
a resolução de dependências e uma compilação fria são consideravelmente mais
demorados que os wrappers locais. No desenvolvimento regular, prefira comandos
como `build-zig.ps1` ou `build-mingw64.ps1` e builds incrementais quando fizer
sentido.

Use `build-sandbox.ps1` em pontos relevantes de validação:

- antes de publicar ou distribuir um build;
- depois de alterar perfis, bootstrap, dependências ou scripts de build;
- ao investigar uma dependência não declarada da máquina host;
- para confirmar as instruções de preparação em um Windows limpo;
- periodicamente, como verificação de reprodutibilidade.

Os caches persistentes de `scratch`, `tools` e dependências aceleram validações
posteriores, mas também significam que uma execução no Sandbox não é
automaticamente um build totalmente frio. Para a verificação mais rigorosa,
revise ou limpe os caches relevantes e comece com `out\<perfil>` vazio.

## Requisitos

- Recurso opcional Windows Sandbox habilitado (`Containers-DisposableClientVM`).
- Virtualização de hardware habilitada e disponível para o Windows.
- `WindowsSandbox.exe` disponível no diretório de sistema.
- Rede para os downloads iniciais do Harbour, toolchains e dependências.
- Espaço livre para `scratch`, `tools`, `out` e dados opcionais do vcpkg.

O launcher recusa iniciar quando detecta outra instância do Windows Sandbox.

## Perfis suportados

```text
zig
zig-win64-gnu
zig-win64-msvc
zig-win32-gnu
zig-win-arm64
zig-linux-x64
zig-linux-arm64
mingw64
```

Perfis excluídos inicialmente:

- `linux-wsl` e `linux-docker`: virtualização ou containers aninhados.
- `msvc64`: o Visual Studio Build Tools é integrado à instalação do host.
- `auto`: depende da detecção ambiente e não é reproduzível.
- `cygwin` e `msys`: exigem provisionamento ainda não implementado.

## Uso básico

Validar sem compilar:

```powershell
.\build-sandbox.ps1 `
  -BuildProfile zig `
  -DryRun `
  -SandboxTimeoutMinutes 10 `
  -KeepSession
```

Build Zig limpo:

```powershell
.\build-sandbox.ps1 `
  -BuildProfile zig `
  -Clean `
  -SandboxTimeoutMinutes 60 `
  -KeepSession
```

Build full sem Qt:

```powershell
.\build-sandbox.ps1 `
  -BuildProfile zig `
  -Full `
  -Clean `
  -IgnoreDependency qt `
  -SandboxTimeoutMinutes 240 `
  -KeepSession
```

## Isolamento e diretórios persistentes

O launcher cria um snapshot em:

```text
%TEMP%\hb_compile-sandbox\<data-hora>\source
```

O convidado copia esse snapshot para `C:\hb_compile`. Assim, o checkout de
trabalho não é modificado diretamente pelo Sandbox.

| Host | Convidado | Finalidade |
| --- | --- | --- |
| `scratch` | `C:\Persistent\scratch` | Checkout e build do Harbour |
| `tools` | `C:\Persistent\tools` | Toolchains e ferramentas |
| `logs` | `C:\Persistent\logs` | Logs de build e dependências |
| `out` | `C:\Persistent\out` | Instalações por perfil |

Junções conectam esses diretórios ao projeto copiado no convidado. Seu conteúdo
permanece depois que a VM é descartada.

## Comportamento importante do clean

`-Clean` solicita a limpeza dos produtos de build do Harbour, mas não garante
que `out\<perfil>` seja esvaziado antes da instalação. Arquivos de builds
anteriores podem permanecer quando o build atual ignora uma dependência ou não
consegue gerar um contrib opcional.

Para uma validação confiável, comece com uma saída vazia:

```powershell
Rename-Item .\out\zig .\out\zig-before-sandbox
New-Item -ItemType Directory .\out\zig
```

Tudo que aparecer no novo diretório pertencerá à nova tentativa de instalação.
Isso é especialmente importante para `rddads`, `sddpg`, `hbpgsql`, `hbcurl` e
DLLs de runtime de terceiros.

Uma data antiga nem sempre prova que o build é inválido, pois arquivos copiados
podem preservar timestamps. Da mesma forma, a presença de um arquivo não prova
que ele foi produzido pela execução atual. Use conjuntamente log, hashes e um
diretório de saída inicialmente vazio.

## Build normal e full

O build normal compila o core e os contribs cujos requisitos já estão
disponíveis. Dependências opcionais ausentes normalmente geram avisos.

O full executa `scripts\Resolve-HarbourDeps.ps1` antes do make. Perfis Windows
nativos usam vcpkg e fallbacks definidos em `config\dependencies.json`.

Builds full podem consumir muito mais tempo e espaço. Qt é particularmente
grande; use `-IgnoreDependency qt` na primeira validação full.

Nem toda dependência opcional é garantida com Zig. Alguns SDKs são manuais,
específicos de arquitetura ou fornecem bibliotecas para outro compilador.
`-StrictDependencies` transforma casos suportados de dependências não resolvidas
em falhas.

## Timeout e duração da VM

`-SandboxTimeoutMinutes` limita quanto tempo o host aguarda `result.json`. Ele
não encerra atualmente a VM nem cancela o build. Se o timeout ocorrer com o
Sandbox aberto, o convidado pode continuar compilando.

Não inicie outro build enquanto a instância existente estiver ativa.

| Build | Timeout inicial sugerido |
| --- | ---: |
| Dry run | 10 minutos |
| Zig normal | 60 minutos |
| Full sem Qt | 240 minutos |
| Full com Qt | 360 minutos ou mais |

O tempo real depende de CPU, disco, rede, cache e dependências escolhidas.

## Parâmetros principais

| Parâmetro | Finalidade |
| --- | --- |
| `-BuildProfile` | Seleciona um perfil suportado |
| `-Full` | Resolve dependências opcionais |
| `-Clean` | Solicita um build limpo do Harbour |
| `-DryRun` | Resolve e mostra comandos sem compilar |
| `-Jobs` | Define o paralelismo do make |
| `-MemoryInMB` | Memória do Sandbox; padrão de 8192 MB |
| `-SandboxTimeoutMinutes` | Limita a espera do host |
| `-NoNetworking` | Desabilita a rede do convidado |
| `-KeepSession` | Preserva requisição, resultado, script e transcript |
| `-KeepOpen` | Mantém o convidado aberto ao finalizar |
| `-LocalWorkspace` | Compila no disco do convidado e sincroniza os diretórios persistentes ao final |
| `-IgnoreDependency` | Exclui dependências opcionais no modo full |
| `-SkipToolBootstrap` | Impede downloads automáticos de toolchains |
| `-StrictDependencies` | Falha em casos suportados não resolvidos |

`-NoNetworking` só deve ser usado quando fontes, ferramentas e dependências já
estiverem nos diretórios persistentes.

### Workspace local opcional

Por padrão, `scratch`, `tools`, `logs` e `out` são usados diretamente por pastas
mapeadas do host. Esse é o modo mais rápido em armazenamento local confiável e
continua sendo o comportamento normal.

Use `-LocalWorkspace` quando o projeto estiver em disco externo ou de rede lento
ou instável:

```powershell
.\build-sandbox.ps1 -BuildProfile zig -Full -Clean -LocalWorkspace
```

O convidado copia para `C:\hb_compile` todo conteúdo persistente que já existir,
baixa normalmente fontes ou ferramentas ausentes, compila no disco virtual local
e copia os quatro diretórios de volta ao host. Não é necessário ter executado um
build anterior nem possuir cache. As cópias inicial e final são validadas; uma
falha de sincronização faz o build do Sandbox falhar mesmo que a compilação tenha
terminado. Mantenha o Sandbox aberto e examine `sandbox.log` se o armazenamento
de destino desconectar durante a cópia final.

## Resultados e diagnóstico

Com `-KeepSession`, examine:

```text
%TEMP%\hb_compile-sandbox\<data-hora>\
  hb-compile.wsb
  request.json
  result.json
  sandbox.log
  source\
```

O log do Harbour fica em `logs\<data-hora>-<perfil>.log`. O transcript cobre o
provisionamento e o launcher; o log do Harbour contém compilador e contribs.

Depois de um build nativo:

```powershell
.\scripts\Test-HarbourInstall.ps1 -Profile zig
```

Esse teste prova que a instalação compila o sample, mas não que todos os
artefatos opcionais foram gerados pela sessão atual.

## Limitações conhecidas

- Saídas persistentes podem conter artefatos antigos.
- Timeout no host não cancela o build convidado.
- Falhas de contribs opcionais podem não falhar a instalação geral.
- Dependências full podem fornecer DLLs específicas de outro compilador.
- Windows Sandbox é interativo; o launcher não é um executor CI headless.
- Estado fora dos diretórios mapeados é descartado.
- Cygwin, MSYS, MSVC, WSL, Docker e autodetecção ainda não são suportados.

## Sequência recomendada

1. Execute `-DryRun -KeepSession` para validar a inicialização.
2. Preserve e esvazie `out\<perfil>`.
3. Execute um build normal com `-Clean`.
4. Examine `sandbox.log` e o log do Harbour.
5. Confirme os executáveis novos e rode `Test-HarbourInstall.ps1`.
6. Execute `-Full -Clean -IgnoreDependency qt` com timeout maior.
7. Compare artefatos opcionais com as mensagens do log.
8. Adicione Qt ou requisitos estritos somente depois de entender o full básico.
