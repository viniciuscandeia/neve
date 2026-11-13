# Changelog

## Em `main` (depois da 0.1.0)

- **Árvore e pisca-pisca:** árvore de Natal no app (ligada por padrão, com opção em Ajustes e "Soltar árvore" no menu), maior e mais rica, com luzes e presentes.
- **Explosão:** o boneco de neve explode sob o cursor em blocos, torrões e pó que carregam o volume dele; a explosão não perde neve.
- **Empurrar, monte e onda:** o cursor empurra a neve com uma lâmina macia (passadas lentas movem pouco, rápidas formam uma borda à frente); o chão ondula só para baixo.
- **Dock:** o monte acompanha o canto arredondado e o quadro final do Dock, mesmo com ele animando; bonecos pulam entre o chão e o topo do Dock.
- **Janelas que somem:** o monte cai em placas e blocos que só quebram ao bater; detecção rápida de "mostrar a área de trabalho" e de janelas novas.
- **Derretimento:** derrete por superfície, a cornija afunda junto e o derretimento ocioso sempre termina.
- **Transbordo e avalanches:** a neve só transborda o que o teto cortou, em blocos com volume; nenhum volume se perde.
- **Obstáculos e profundidade:** janelas são paredes para os detritos; flocos grandes e desfocados no primeiro plano; neve cobre as partes de trás.
- **Flocos, máscara e modo compacto:** flocos grandes viram cristais de seis braços; gelo, geada e cantos respeitam as janelas à frente; modo de economia.
- **Atores:** boneco, trenó e visitantes corrigidos (brigas, sumir, colapso, saltos).
- **Áudio:** a captura só roda enquanto a neve é desenhada e reinicia ao trocar a saída de som; nível, grave e batida protegidos por lock.
- **Desempenho:** medição na tela (`scripts/perf.sh`, `scripts/perf-suite.sh`) com hitch, energia e memória; tabelas de luz por quadro, pilhas e relaxamento só onde algo mudou; limite de CPU da Nevasca com varredura em 15%.
- **Qualidade e testes:** suíte Swift Testing (`Tests/run.sh`, com verificação dos shaders e sanitizadores), testes fortalecidos, localização pt-BR/English, release validado, scripts de build mais robustos.

## 0.1.0

Primeira versão publicada: neve que cai e se acumula sobre as janelas, o Dock e o chão, empurrada pelo cursor, no app de barra de menus.
