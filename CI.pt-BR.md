# Validação contínua

[English](CI.md) | **Português (Brasil)**

O `hb_compile` usa dois workflows do GitHub Actions.

## CI obrigatória

O `hb_compile CI` é executado em pushes para `main`, pull requests e
acionamentos manuais. Ele:

- analisa sintaticamente todos os scripts PowerShell versionados;
- valida as configurações JSON;
- resolve o perfil Docker em modo de simulação;
- realiza um build mínimo do Harbour no Docker Linux; e
- compila e executa `samples/hello.prg` usando a instalação produzida.

Os logs são mantidos como artefatos do workflow mesmo quando o build falha.
Como os runners hospedados pelo GitHub usam um workspace descartável, a CI não
solicita `-Clean`; isso também evita executar, durante a limpeza, binários
deixados por outra imagem Docker.

## Validação completa

O `hb_compile full validation` executa todo domingo um build full básico no
Docker Linux. Ele também pode ser acionado manualmente com um destes modos:

- `none`;
- `hbdap`;
- `openads`; ou
- `hbdap-openads`.

O Qt é excluído porque não é necessário para HBDAP ou OpenADS e aumenta
consideravelmente o custo do runner. O workflow valida `hello.prg` e os
artefatos instalados solicitados explicitamente pelo modo escolhido.

O HBDAP é privado. Antes de selecionar um modo com HBDAP, configure o secret
de Actions `HBDAP_CROSS_REPO_TOKEN` com acesso de leitura ao repositório do
HBDAP. Quando a integração é solicitada sem esse secret, o workflow falha
imediatamente. Os modos básico e OpenADS não precisam dele.

O WSL permanece como alvo de validação local/manual. Os runners hospedados
pelo GitHub não oferecem o mesmo ambiente WSL usado pelo projeto; o build
Docker Linux é seu equivalente reproduzível na CI.
