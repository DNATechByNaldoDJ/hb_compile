# hbdap opcional no build Harbour

[English](HBDAP.md) | **Português (Brasil)**

O `hb_compile` pode incluir o [hbdap](https://github.com/DNATechByNaldoDJ/hbdap)
como contrib opcional do Harbour. A integração é opt-in: nenhum build existente
muda enquanto `-WithHbdap` não for informado.

## Uso

```powershell
.\build-zig.ps1 -WithHbdap
.\build-full-zig.ps1 -WithHbdap -IgnoreDependency qt
.\build-full-linux-wsl.ps1 -WithHbdap -IgnoreDependency qt
.\build-full-linux-docker.ps1 -WithHbdap -IgnoreDependency qt
```

O runner procura primeiro um checkout irmão em `..\hbdap`. Se ele não existir,
clona o repositório padrão em `scratch\hbdap`. Também é possível controlar a
origem:

```powershell
.\build-zig.ps1 -WithHbdap `
  -HbdapRoot D:\fontes\hbdap `
  -HbdapRef v0.1.0-alpha
```

Parâmetros disponíveis:

- `-WithHbdap`: habilita a integração.
- `-HbdapRoot`: usa um checkout local específico.
- `-HbdapRepository`: altera a origem usada quando o checkout não existe.
- `-HbdapRef`: seleciona uma branch, tag ou commit em um checkout Git.

## O que o build faz

Antes de chamar `make`, `scripts\Install-HbdapContrib.ps1`:

1. resolve ou clona o checkout hbdap;
2. copia somente `hbdap.hbp`, `hbdap.hbc`, `LICENSE`, `include\` e `src\`;
3. instala o conteúdo em `contrib\hbdap`;
4. registra `hbdap/hbdap.hbp` em `contrib\hbplist.txt`;
5. grava `HBDAP_BUILD_INFO.json` com origem e revisão.

O próprio sistema de contribs do Harbour compila a biblioteca. Isso mantém o
mesmo comportamento nos runners Windows, Cygwin, MSYS, WSL e Docker.

## Escopo atual

Esta primeira integração instala a biblioteca hbdap. A instalação automática
de `hbdap_adapter` e `hbdap_cli`, testes integrados e empacotamento versionado
estão no roadmap de [TODO.pt-BR.md](TODO.pt-BR.md).

O hbdap atualmente requer extensões controladas no core Harbour, incluindo
`hb_conSetOutputFunc`. A revisão efetiva do Harbour e do hbdap deve ser
registrada e validada em conjunto.

## Armazenamento e builds Linux

Builds full geram I/O intenso. Se o workspace estiver em disco externo, VHD,
unidade criptografada ou rede, prefira uma cópia local estável. Erros de
paginação do Windows (`disk`, evento 51), desmontagem da unidade ou falhas do
BitLocker não são erros do WSL/Docker e devem ser resolvidos antes de repetir o
build.

Para excluir Qt de um full build:

```powershell
.\build-full-linux-wsl.ps1 -WithHbdap -IgnoreDependency qt
.\build-full-linux-docker.ps1 -WithHbdap -IgnoreDependency qt
```

O `DryRun` deve mostrar `HB_WITH_QT=no`, `HB_BUILD_CONTRIBS='no gtqtc'` e, no
Docker, `INSTALL_QT=0`.
