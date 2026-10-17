<p align="center">
  <img src="docs/media/icon.png" width="128" alt="Ícone do NiriOS">
</p>

<h1 align="center">NiriOS</h1>

<p align="center">
  Janelas em fita, ferramentas do dia a dia e uma mesa com a sua cara, num app leve para o macOS.<br>
  Inspirado no <a href="https://github.com/niri-wm/niri">niri</a>. Funciona com o SIP ligado.
</p>

<p align="center">
  <a href="README.md">English</a> · <b>Português</b>
</p>

<p align="center">
  <img src="docs/media/demo.gif" alt="NiriOS rolando entre colunas, mudando a largura de uma coluna e trocando de workspace">
</p>

O NiriOS nasceu como um gerenciador de janelas no estilo do niri e está virando um app só para resolver o macOS do dia a dia: como as janelas se movem, como a mesa fica e as ferramentas pequenas que o Mac não traz. Toda parte é opcional, e nenhuma pode custar velocidade ou memória.

## Janelas

As janelas ficam em colunas numa fita horizontal sem fim. Abrir uma janela nunca encolhe as outras: a fita só rola.

- **Colunas que rolam.** A coluna pula entre 1/3, 1/2, 2/3 e a tela toda, troca de lugar com a vizinha e pode ter várias janelas empilhadas.
- **Fluido até com app lento.** A animação segue a taxa da tela (120 Hz no ProMotion), cada app tem a própria fila e nada é lido do app no meio da animação. Um app lento só atrasa as janelas dele.
- **Resize fantasma.** Enquanto a coluna muda de largura, um vidro fosco com o ícone do app anda no lugar dela. A janela real volta quando terminou de redesenhar, então você nunca vê um quadro esticado ou pela metade, nem em app Electron.
- **Workspaces que deslizam.** Uma fita por workspace, lado a lado. Dá para fixar apps num workspace, e uma SketchyBar feita para o AeroSpace funciona com uma linha de config.
- **Mostrar a mesa.** As janelas saem pela borda mais próxima e voltam com a mesma tecla.

<p align="center">
  <img src="docs/media/columns.gif" width="840" alt="Movendo uma coluna, empilhando duas janelas numa coluna e mostrando a mesa">
</p>

## Ferramentas do dia a dia

### Histórico do clipboard

`⌥ V` abre as últimas 25 cópias, texto e imagem, junto do cursor. Digite para filtrar, `↩` cola, e `⌘ P` fixa até 10 favoritos. O que gerenciador de senha marca como sigiloso nunca é guardado. Nada fica consultando o clipboard: o NiriOS só confere depois de um atalho com `⌘`, de um Return ou de um clique.

<p align="center">
  <img src="docs/media/clipboard.gif" width="560" alt="Abrindo o histórico do clipboard, filtrando, colando um texto e uma imagem">
</p>

### Print

`⌥ S` congela a tela no momento da tecla, então menu aberto e efeito de passar o mouse ficam no print. Arraste pra escolher a área e desenhe com caneta, linha, seta, retângulo ou marca-texto, escreva, ou pixele o que não deve aparecer. `⌘ C` ou `↩` copia, `⌘ S` salva na pasta de prints do macOS (ou em `screenshotFolder`), `Esc` cancela e `⌘ Z` desfaz. A rolagem do mouse muda a espessura, o Shift deixa linha em 45° e retângulo quadrado, e cada ferramenta tem uma letra (aparece na dica do botão).

## Com a sua cara

### Papel de parede animado

Use um vídeo como papel de parede. Ele só toca com a mesa à mostra, e roda num processo próprio para o NiriOS continuar pequeno.

<p align="center">
  <img src="docs/media/wallpaper.gif" width="720" alt="Um vídeo de papel de parede tocando depois que as janelas saem da frente">
</p>

Imagem pode ganhar um efeito de pixel. Ele é gerado uma vez e entregue ao macOS, então depois não custa nada.

<p align="center">
  <img src="docs/media/wallpaper-effects.png" width="880" alt="O mesmo papel de parede original, com dither, meio-tom, scanlines e ASCII">
</p>

### Borda de foco

Um contorno na janela focada, com o canto de cada app. Ela se move pelos avisos do WindowServer, não pelo layout calculado, então fica grudada na janela: medida a 120 fps, fica no lugar em 99,6 a 100% dos quadros. Cor e espessura mudam assim que você salva.

<p align="center">
  <img src="docs/media/border.gif" width="420" alt="A borda mudando de cor e espessura a cada vez que o config é salvo">
</p>

### Configurações

Tudo fica num arquivo JSON, e o ícone da barra de menu abre um painel que grava nele. O painel é outro processo e sai quando você fecha.

<p align="center">
  <img src="docs/media/settings-workspaces.png" width="410" align="top" alt="Aba Workspaces: os apps que abrem no workspace 2 e os atalhos dele">
  <img src="docs/media/settings-border.png" width="410" align="top" alt="Aba Borda: cor e espessura com prévia">
</p>

## Feito para continuar leve

Uma ferramenta que fica aberta o dia todo tem que custar quase nada. No NiriOS isso é regra, não meta:

- **Parado é parado.** Sem polling, sem timer, sem display link quando nada se mexe: 0% de CPU.
- **Desligado não existe.** Recurso desligado não tem janela, monitor de eventos nem memória no NiriOS, e o atalho dele volta para os seus apps.
- **Trabalho pesado roda fora.** O painel, a leitura do clipboard, o editor do print, o papel de parede e o update são processos separados que saem quando terminam, então a memória deles nunca fica para trás.
- **A memória não cresce.** O estado de uma janela some com a janela. Ligando e desligando recursos 60 vezes seguidas, a memória estabilizou nas primeiras vezes e ficou ali.
- **Estabilidade vem antes de recurso.** Glitch, janela fora do lugar ou leitura de Acessibilidade a mais é bug, mesmo que o recurso funcione. Mudança que piore os números abaixo precisa de justificativa.

| Medido num MacBook Pro (Apple Silicon) | |
|---|---|
| NiriOS parado | 10 a 12 MB, 0% de CPU |
| Borda de foco | +0,2 a 0,5 MB |
| Histórico do clipboard | +0,2 a 0,4 MB (uma imagem de 30 MB é lida em outro processo e nunca entra no NiriOS) |
| Print | a foto sai do NiriOS assim que é tirada (10 MB antes e depois); o editor tem 17 a 22 MB, num processo próprio |
| Resize fantasma, durante a animação | ~2,5% de CPU |
| Papel de parede em vídeo, 4K a 60 fps | 32 MB e 3% de CPU, num processo próprio |

Cada medição e cada caminho testado e descartado estão nas [notas de engenharia](docs/NOTES.md).

## Comparado com os outros

| | NiriOS | [OmniWM](https://github.com/OmniNull/OmniWM) | [Paneru](https://github.com/karinushka/paneru) | [AeroSpace](https://github.com/nikitabobko/AeroSpace) | [yabai](https://github.com/asmvik/yabai) |
|---|---|---|---|---|---|
| Layout | Colunas em fita | Fita ou dwindle | Colunas em fita | Árvore estilo i3 | BSP |
| Animações | Sim | Sim | Sim | Não | Sim, com o SIP parcialmente desligado |
| Tudo funciona com o SIP ligado | Sim | Sim | Não documentado | Sim | Não |
| Workspaces | Próprios, deslizam de lado | Próprios | Spaces nativos | Próprios | Spaces nativos |
| Borda de foco embutida | Sim | Sim | Não documentado | Não | Não |
| Licença | GPL-3.0 | GPL-2.0 | MIT | MIT | MIT |

<sub>Pela documentação de cada projeto, outubro de 2026. Correções são bem-vindas.</sub>

O que mais diferencia o gerenciador de janelas é o que ele se recusa a fazer:

- **Não lê nada durante a animação.** Cada leitura pela Acessibilidade é uma ida e volta que trava o app. Enquanto a fita anda, o NiriOS só escreve os quadros, e confere as posições depois que ela assenta.
- **Não monta pipeline por quadro.** Um tick é a fórmula fechada da mola e uma lista de retângulos. Trocar o alvo no meio preserva a velocidade, e um quadro atrasado não entorta a trajetória.
- **Não troca o foco no meio do movimento.** Ativar cada app que passa pela tela trava todos eles (num teste, a janela do Arc ficou 403 ms sem se mexer), então o foco muda quando a fita assenta.
- **Não chuta.** Janela só sai do layout com evento real de janela. Timeout não é janela fechada, e janela em outro Space não conta como sumida.

## Instalar

```sh
brew install --cask deandevz/tap/niri-os
```

Precisa do macOS 15 ou mais novo, em Apple Silicon. Desenvolvido e medido no macOS 26 Tahoe. Feche outros gerenciadores de janela antes.

Na primeira abertura, um tour pede as permissões e deixa escolher o que ligar. A Acessibilidade é obrigatória. A Gravação de Tela é opcional: com ela, o resize fantasma espera o app terminar de redesenhar e a borda mede o canto de janela quadrada. O NiriOS procura atualização uma vez por dia e pergunta antes de instalar.

O app é autoassinado e ainda não é notarizado, então o cask do Homebrew tira a quarentena depois de instalar.

### Compilar do código

Precisa do Swift 6 (Xcode ou Command Line Tools).

```sh
git clone https://github.com/deandevz/NiriOS.git
cd NiriOS
./scripts/run.sh      # compila em release e roda; -v mostra as medições de cada animação
./scripts/test.sh     # testes do layout e da mola
```

O terminal que roda o NiriOS precisa da permissão de Acessibilidade. `Ctrl+C` devolve todas as janelas para a tela e sai.

## Atalhos

| Atalho | Ação |
|---|---|
| `⌥ ,` `⌥ .` ou `⌥ ←` `⌥ →` | Foco na coluna da esquerda ou da direita |
| `⌥ ⇧ ,` `⌥ ⇧ .` ou `⌥ ⇧ ←` `⌥ ⇧ →` | Move a coluna para a esquerda ou para a direita |
| `⌥ +` `⌥ −` | Largura da coluna: 1/3, 1/2, 2/3, tela toda |
| `⌥ F` | Tela toda; de novo volta |
| `⌥ ⌘ ,` `⌥ ⌘ .` | Empilha a janela na coluna vizinha, ou tira da pilha |
| `⌥ ⌘ +` `⌥ ⌘ −` | Altura da janela numa coluna empilhada |
| `⌥ ↑` `⌥ ↓` | Foco na de cima ou na de baixo, numa coluna empilhada |
| `⌥ 1` a `⌥ 4` | Vai para um workspace |
| `⌥ ⇧ 1` a `⌥ ⇧ 4` | Manda a janela focada para um workspace |
| `⌥ D` | Mostra a mesa; de novo as janelas voltam |
| `⌥ V` | Histórico do clipboard |
| `⌥ S` | Print de uma área, com ferramentas de desenho |

A tecla vale pela posição no teclado, então fica no mesmo lugar em qualquer layout (US, ABNT2). Todo atalho pode ser trocado.

## Configuração

Clique no ícone da barra de menu para abrir o painel, ou edite `~/.config/niri-os/config.json`. Salvar aplica na hora, e gap, margens e mola animam até o lugar novo. Toda chave é opcional:

```json
{
  "gap": 12,
  "borderColor": "#C283FF",
  "borderWidth": 4.5,
  "wallpaper": "~/Movies/aurora.mp4",
  "workspaces": [
    "1",
    { "name": "2", "apps": ["Calendar", "com.hnc.Discord"] },
    { "name": "T", "apps": ["com.github.wez.wezterm"], "open": "WezTerm" }
  ],
  "shortcuts": { "toggleDesktop": ["ctrl+option+d"] },
  "onWorkspaceChange": "sketchybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$NIRI_WORKSPACE",
  "features": { "clipboard": false }
}
```

| Chave | Padrão | O que faz |
|---|---|---|
| `gap` | `12` | Espaço entre janelas e em volta da tela, em pontos |
| `topPadding`, `bottomPadding` | `0` | Espaço extra, para uma barra como a SketchyBar |
| `defaultColumnWidth` | `0.5` | Largura da janela nova, como fração da tela |
| `widthPresets` | `[0.333, 0.5, 0.667, 1]` | Larguras do `⌥ +` e do `⌥ −` |
| `heightPresets` | `[0.333, 0.5, 0.667]` | Alturas numa coluna empilhada |
| `centerFocusedColumn` | `"always"` | `always`, `never` ou `on-overflow` |
| `stiffness` | `800` | Rigidez da mola; maior é mais rápido (800 dá uns 0,35 s, como no niri) |
| `resizeStyle` | `"ghost"` | `ghost`, `photos` (precisa da Gravação de Tela) ou `live` |
| `borderColor`, `borderWidth` | cor de destaque, `3` | `#RRGGBB`, `#RRGGBBAA` ou `accent`; largura `0` tira a borda |
| `workspaces` | `1` a `4` | Na ordem da tela; cada um pode ter `apps`, `open` (app que abre quando ele está vazio), `key` e `moveKey` |
| `onWorkspaceChange` | nenhum | Comando de shell rodado a cada troca, com o nome em `$NIRI_WORKSPACE` |
| `wallpaper`, `wallpaperEffect` | nenhum | Imagem ou vídeo (`.mp4`, `.mov`, `.m4v`); efeitos de imagem `dither`, `halftone`, `scanlines`, `ascii` |
| `screenshotFolder` | a pasta de prints do macOS | Onde o `⌘ S` salva o print |
| `shortcuts` | | Uma lista por ação; `[]` desliga |
| `features` | tudo ligado | `tiling`, `border`, `clipboard`, `screenshot`, `wallpaper`; `false` desliga |

Atalho é modificador (`ctrl`, `option`, `shift`, `cmd`) mais tecla, como `"option+shift+left"`. Ações: `grow`, `shrink`, `growHeight`, `shrinkHeight`, `focusLeft`, `focusRight`, `focusUp`, `focusDown`, `moveColumnLeft`, `moveColumnRight`, `consumeOrExpelLeft`, `consumeOrExpelRight`, `toggleFullWidth`, `toggleDesktop`, `clipboard` e `screenshot`. Para workspaces clicáveis numa barra, `/Applications/NiriOS.app/Contents/MacOS/niri-os --workspace <nome>` troca pela linha de comando.

## Limitações

O NiriOS é novo. Espere arestas, e abra uma issue quando achar uma.

- Só a tela principal é gerenciada. O print é da tela onde está o mouse.
- Ainda não tem janela flutuante: toda janela comum entra na fita.
- Diálogos e sheets flutuam, mas ainda não ficam centralizados sobre a janela dona.
- App com largura mínima maior que a coluna invade a vizinha.
- Janelas de apps diferentes podem ficar um quadro desencontradas durante a animação, porque cada app aplica os quadros na própria fila.
- O painel de configurações e o tour da primeira abertura estão só em português por enquanto.
- O NiriOS usa APIs privadas do SkyLight (todas funcionam com o SIP ligado), então uma atualização do macOS pode quebrar alguma parte.

## Contribuir

Issues e pull requests são bem-vindos. O [CONTRIBUTING.md](CONTRIBUTING.md) (em inglês) explica o que o projeto valoriza, as regras de arquitetura, como testar sem mexer nas suas janelas e o que mandar numa issue ou num pull request.

## Agradecimentos

O NiriOS se apoia no [niri](https://github.com/niri-wm/niri) pelo modelo de layout e animação, no [yabai](https://github.com/asmvik/yabai) pelo mapa das APIs do SkyLight, no [AeroSpace](https://github.com/nikitabobko/AeroSpace) por mostrar que dá para ter workspaces sem desligar o SIP, no [OmniWM](https://github.com/OmniNull/OmniWM) e no [Paneru](https://github.com/karinushka/paneru) por explorarem o niri no Mac, no [JankyBorders](https://github.com/FelixKratz/JankyBorders) pelo jeito de achar o canto das janelas e no [Loop](https://github.com/MrKai77/Loop) pela ideia por trás do resize fantasma.

## Licença

O NiriOS é software livre, sob a [GNU General Public License v3.0 ou posterior](LICENSE). Você pode usar, estudar, modificar e compartilhar. Qualquer versão distribuída, modificada ou não, tem que continuar com o código aberto e sob a mesma licença.
