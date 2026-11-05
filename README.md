# Neve ❄

Neve faz nevar sobre a tela do seu Mac, acumulando nas janelas e no Dock.

<!-- screenshot -->

App nativo de barra de menus para macOS, escrito em Swift 6 com AppKit e Metal, sem dependências externas.

## Recursos

- A neve cai sobre toda a tela, por cima de tudo, e nunca bloqueia cliques (overlay click-through).
- Os flocos se acumulam na borda superior das janelas e no Dock.
- A neve escorrega pelos cantos arredondados das janelas.
- Ao arrastar, minimizar ou fechar uma janela, a neve acumulada nela cai.
- Ícone de floco de neve na barra de menus com:
  - **Nevar**: liga e desliga a neve.
  - **Quantidade**: Leve, Média, Forte ou Nevasca (a Nevasca adiciona um vento que muda de direção continuamente).
  - **Limpar neve**: remove a neve acumulada.
  - **Sair**.
- Não exige permissão de Gravação de Tela nem de Acessibilidade: apenas os limites (bounds) das janelas são lidos.

## Requisitos

- macOS 14 ou superior
- Toolchain Swift 6. As Command Line Tools bastam; o Xcode não é necessário.

## Como rodar

```sh
swift build -c release
.build/release/Neve
```

Testes:

```sh
swift test
```

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
