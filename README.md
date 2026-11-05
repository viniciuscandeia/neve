# Neve ❄

Neve faz nevar sobre a tela do seu Mac, acumulando nas janelas e no Dock.

![Neve: neve caindo e acumulando sobre janelas e o Dock](docs/demo.gif)

App nativo de barra de menus para macOS, escrito em Swift 6 com AppKit e Metal, sem dependências externas.

## Recursos

- A neve cai sobre toda a tela, por cima de tudo, e nunca bloqueia cliques (overlay click-through).
- Os flocos se acumulam na borda superior das janelas e no Dock.
- A neve escorrega pelos cantos arredondados das janelas.
- Passe o cursor sobre a neve acumulada para derrubá-la.
- Ao arrastar, minimizar ou fechar uma janela, a neve acumulada nela cai.
- Ícone de floco de neve na barra de menus (fica esmaecido quando a neve está pausada ou desligada). O menu nativo mostra:
  - Linha de status no topo, atualizada ao abrir o menu (ex.: "Nevando · Média", "Pausado — app em tela cheia", "Desligado").
  - **Nevar** (⌘N): liga e desliga a neve.
  - **Quantidade**: Leve, Média, Forte ou Nevasca (a Nevasca adiciona um vento que muda de direção continuamente).
  - **Opções**: **Modo econômico** (30 fps e neve só no monitor principal, o da barra de menus; a escolha é lembrada), **Abrir no login** e, quando falta a permissão, **Permitir neve no Dock…**.
  - **Limpar neve** (⌘K): remove a neve acumulada.
  - **Sair** (⌘Q).
- Por padrão a neve não aparece em capturas de tela, gravações de tela nem compartilhamento de tela; ative "Mostrar em capturas" (em OPÇÕES) para incluí-la, por exemplo ao gravar uma demo.
- Não exige Gravação de Tela: apenas os limites (bounds) das janelas são lidos.
- A permissão de Acessibilidade é opcional e só serve para a neve acumular no Dock (apenas Dock na parte inferior da tela). Sem ela, tudo o mais funciona. Use "Permitir neve no Dock…" no menu.
- A animação pausa sozinha sob apps em tela cheia e com o Mac em estado térmico alto; no Modo de Baixo Consumo roda a 30 fps.

## Requisitos

- macOS 14 ou superior
- Toolchain Swift 6. As Command Line Tools bastam; o Xcode não é necessário.

## Como rodar

```sh
swift build -c release
.build/release/Neve
```

Para gerar um app (`build/Neve.app`) cujas permissões sobrevivem a recompilações, crie uma vez uma identidade de assinatura local e depois empacote:

```sh
scripts/make-cert.sh   # uma vez; pede a senha do login para confiar no certificado
scripts/make-app.sh
```

O macOS associa a permissão de Acessibilidade à assinatura do app. Com a assinatura ad-hoc (padrão), cada build muda a assinatura e a permissão é perdida; com a identidade estável "Neve Local Signing" ela é mantida. Se a identidade não existir, `make-app.sh` avisa e assina ad-hoc.

Autoteste rápido:

```sh
.build/release/Neve --selftest
```

Testes unitários (Swift Testing):

```sh
Tests/run.sh
```

Com apenas as Command Line Tools, `swift test` compila os testes mas não os executa; o script `Tests/run.sh` cuida de rodá-los.

## Instalação

1. Gere o app: `scripts/make-cert.sh` (uma vez) e `scripts/make-app.sh`.
2. Mova `build/Neve.app` para `/Applications` (necessário para o item de login funcionar de forma confiável) e abra.
3. No menu, marque **Abrir no login** para iniciar o Neve junto com o Mac. Se o macOS pedir aprovação, ative o Neve em Ajustes do Sistema > Geral > Itens de Início de Sessão.

O Neve permite apenas uma instância: abrir de novo não faz nada. A opção **Nevar** é lembrada entre execuções.

### Abrir em outro Mac

O app não é notarizado (não há Apple Developer ID), então o Gatekeeper o bloqueia ao ser copiado para outro Mac. Para abrir:

- clique com o botão direito no app e escolha **Abrir**; ou, no macOS 15 ou superior, vá em Ajustes do Sistema > Privacidade e Segurança > **Abrir Mesmo Assim**; ou
- rode `xattr -dr com.apple.quarantine /Applications/Neve.app`.

Compilar a partir do código-fonte no próprio Mac de destino evita o bloqueio.

## Como funciona

- Uma janela de overlay transparente cobre a tela, acima das demais e ignorando eventos do mouse.
- A posição das janelas visíveis é lida periodicamente e convertida em um mapa de superfícies por coluna de pixels: para cada coluna, a altura da superfície mais alta em que um floco pode pousar.
- Ao pousar, o floco alimenta uma pilha de neve naquela coluna. As pilhas escorregam nos cantos arredondados e desabam quando a janela se move, é minimizada ou fechada.
- O shader Metal é compilado em tempo de execução a partir de código-fonte, porque as Command Line Tools não incluem o compilador `metal`.

## Desempenho

- Renderização instanciada na GPU: todos os flocos em uma única draw call.
- Física sobre um pool fixo de structs, sem alocação por frame.
- As pilhas só são redesenhadas quando mudam.
- A animação pausa quando a tela entra em repouso ou a neve está desligada.
- Menos flocos quando o Modo de Baixo Consumo está ativo.

## Licença

MIT. Veja o arquivo `LICENSE`.
