# TODO

[English](TODO.md) | **Português (Brasil)**

## Integração contínua

- [x] Restabelecer a validação Docker full agendada depois de corrigir o
  encaminhamento dos parâmetros nomeados PowerShell para
  `-IgnoreDependency qt`. A execução manual `31702395638` e a CI do push
  `31702377181` foram aprovadas em 2026-08-13.
- [ ] Substituir o encaminhamento `@args` cru dos wrappers de nível superior
  por parâmetros nomeados tipados, mantendo seguro o splatting de hashtable
  fora da CI.
- [x] Validar PowerShell, configurações JSON, build Docker mínimo e
  `hello.prg` em pushes e pull requests.
- [x] Oferecer validação Docker full agendada/manual com modos opcionais para
  HBDAP e OpenADS.
- [ ] Adicionar validação WSL quando houver um runner auto-hospedado adequado.

## hbdap

- [x] Tornar a inclusão do hbdap opt-in com `-WithHbdap`.
- [x] Aceitar checkout, repositório e revisão por `-HbdapRoot`,
  `-HbdapRepository` e `-HbdapRef`.
- [x] Integrar a biblioteca pelo fluxo nativo `contrib/hbdap`.
- [x] Registrar origem e revisão em `HBDAP_BUILD_INFO.json`.
- [x] Instalar `hbdap_adapter` e `hbdap_cli` em `out/<perfil>/bin` nos runners
  Windows, WSL e Docker suportados.
- [x] Executar a suíte hbdap completa após builds Windows, WSL e Docker. A
  imagem Docker full inclui PowerShell 7 fixado e executa a suíte canônica
  dentro do container; o consumidor público mínimo permanece automático.
- [x] Produzir manifesto conjunto com revisões Harbour e hbdap, perfil, runner
  e hashes do adapter/CLI.
- [ ] Empacotar Harbour + hbdap para o `v0.1.0-alpha`.

## Testes integrados de contribs opcionais

- [x] Criar `scripts/Test-OptionalContribs.ps1` para testar OpenADS e HBDAP
  somente quando solicitados.
- [x] Validar a solicitação e os artefatos instalados antes do teste funcional:
  `librddads`, `libace`, `libhbdap` e metadados do build.
- [ ] Compilar e executar um programa Harbour mínimo que crie, abra e consulte
  uma tabela por `rddads` em WSL e Docker.
- [x] Compilar e executar um consumidor Harbour mínimo da API pública do HBDAP
  nos perfis suportados. Windows, Docker e WSL passaram com a revisao Harbour
  atual; o build limpo WSL usou dois jobs e excluiu Qt.
- [x] Integrar a suíte própria do HBDAP quando o checkout estiver disponível,
  reutilizando sua entrada canônica `test-hb_compile.ps1`.
- [x] Incluir `hbdap_adapter` e `hbdap_cli` no teste depois que forem instalados
  em `out/<perfil>/bin`.
- [x] Expor os testes pela matriz de `Test-HarbourBuilds.ps1` com níveis
  explícitos `None`, `Smoke` e `Full`, distinguindo compilação/link, smoke
  público e suíte completa.

## Linux e armazenamento

- [x] Adicionar OpenADS opt-in para WSL e Docker com `-WithOpenAds`.
- [x] Validar `librddads.a` e `libace.so` em builds full WSL e Docker.
- [ ] Executar um smoke test Harbour/OpenADS nos dois runners Linux.
- [x] Concluir builds full WSL e Docker com `-IgnoreDependency qt`.
- [x] Validar hbdap nos artefatos `linux-wsl` e `linux-docker`. O build limpo
  WSL, a instalacao das ferramentas, o manifesto conjunto e o smoke publico
  passaram em 2026-08-13 com a revisao Harbour `6df4c08b98`.
- [ ] Permitir que logs usem um diretório em volume diferente do workspace.
- [ ] Detectar e abortar cedo quando o volume do workspace desaparecer.
- [ ] Documentar uma estratégia de workspace local para disco externo, VHD,
  BitLocker ou compartilhamento instável.

## Compatibilidade com o Harbour 3.2.1dev

- [x] Fazer `-Jobs` controlar também o paralelismo interno das contribs, sem
  deixar o `contrib/make.hb` elevar implicitamente o limite para oito.
- [x] Corrigir os nomes de vínculo de OpenSSL e libmagic vindos do vcpkg nos
  builds Windows com Zig.
- [x] Tratar mensagens `hbmk2: Erro/Error` como falha do build mesmo quando o
  `make` de contribs retorna código zero.
- [x] Fornecer `safe.directory` local ao processo Git em todos os runners, sem
  alterar a configuração global do usuário, preservando `GIT_REVISION`.
- [x] Validar incrementalmente o build full Zig com Harbour `6df4c08b98`, dois
  jobs, contribs `hbssl`/`hbmagic` e execução de `hello.prg`.

## Caminho coordenado com HBDAP e a extensão VS Code

1. Tornar reutilizável a validação de contribs opcionais, começando pela
   conferência dos artefatos e por um consumidor HBDAP mínimo nos perfis
   suportados do `hb_compile`.
2. Instalar e validar `hbdap_adapter` e `hbdap_cli`, produzindo depois um
   manifesto conjunto das revisões Harbour/HBDAP.
3. Entregar metadados e artefatos reproduzíveis ao teste de instalação limpa
   compartilhado pelo HBDAP e pela extensão VS Code.
4. Empacotar somente depois que o candidato coordenado a
   `v0.1.0-alpha.1` passar pelos fluxos do core, CLI, adapter e VSIX empacotado.
