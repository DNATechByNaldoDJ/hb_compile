# TODO

[English](TODO.md) | **Português (Brasil)**

## hbdap

- [x] Tornar a inclusão do hbdap opt-in com `-WithHbdap`.
- [x] Aceitar checkout, repositório e revisão por `-HbdapRoot`,
  `-HbdapRepository` e `-HbdapRef`.
- [x] Integrar a biblioteca pelo fluxo nativo `contrib/hbdap`.
- [x] Registrar origem e revisão em `HBDAP_BUILD_INFO.json`.
- [ ] Instalar `hbdap_adapter` e `hbdap_cli` em `out/<perfil>/bin`.
- [ ] Executar a suíte hbdap após builds Windows, WSL e Docker.
- [ ] Produzir manifesto conjunto com revisões Harbour e hbdap.
- [ ] Empacotar Harbour + hbdap para o `v0.1.0-alpha`.

## Testes integrados de contribs opcionais

- [ ] Criar `scripts/Test-OptionalContribs.ps1` para testar OpenADS e HBDAP
  somente quando solicitados.
- [ ] Validar a solicitação e os artefatos instalados antes do teste funcional:
  `librddads`, `libace`, `libhbdap` e metadados do build.
- [ ] Compilar e executar um programa Harbour mínimo que crie, abra e consulte
  uma tabela por `rddads` em WSL e Docker.
- [ ] Compilar e executar um consumidor Harbour mínimo da API pública do HBDAP
  nos perfis suportados.
- [ ] Integrar a suíte própria do HBDAP quando o checkout estiver disponível.
- [ ] Incluir `hbdap_adapter` e `hbdap_cli` no teste depois que forem instalados
  em `out/<perfil>/bin`.
- [ ] Expor os testes pela matriz de `Test-HarbourBuilds.ps1`, distinguindo
  compilação/link, smoke funcional e suíte completa.

## Linux e armazenamento

- [x] Adicionar OpenADS opt-in para WSL e Docker com `-WithOpenAds`.
- [x] Validar `librddads.a` e `libace.so` em builds full WSL e Docker.
- [ ] Executar um smoke test Harbour/OpenADS nos dois runners Linux.
- [x] Concluir builds full WSL e Docker com `-IgnoreDependency qt`.
- [x] Validar hbdap nos artefatos `linux-wsl` e `linux-docker`.
- [ ] Permitir que logs usem um diretório em volume diferente do workspace.
- [ ] Detectar e abortar cedo quando o volume do workspace desaparecer.
- [ ] Documentar uma estratégia de workspace local para disco externo, VHD,
  BitLocker ou compartilhamento instável.
