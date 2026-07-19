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
