# NiriOS: notas de engenharia

O caderno técnico do projeto: como cada parte funciona, o que foi medido e o que foi testado e descartado. Pra instalar e usar, veja o [README](../README.md) ([em português](../README.pt-BR.md)).

## Instalar

`brew install --cask deandevz/tap/niri-os` (macOS 15 ou mais novo, Apple Silicon; medido só no 26). Na primeira abertura, o tour pede as permissões e deixa escolher o que ligar. O app se atualiza sozinho (seção "Distribuição").

## Rodar do código

1. Feche o OmniWM (com a fita ligada, o niri-os se recusa a abrir com ele rodando: os dois brigariam pelas janelas).
2. O terminal que roda o niri-os precisa de permissão em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade.
3. `./scripts/run.sh` (ou `./scripts/run.sh -v` pra ver as medições de cada animação). Rodando do `.build` não tem tour, update nem abrir ao iniciar, e o log fica no terminal.
4. Clique (esquerdo ou direito) no ícone da barra de menu (três colunas) abre o painel de configurações.
5. `Ctrl+C`, ou "Sair do NiriOS" no painel, devolve todas as janelas pra dentro da tela e sai.

| Atalho | Ação |
|---|---|
| `Option +` / `Option -` | largura da coluna focada: pula entre 1/3, 1/2, 2/3 e tela cheia (como no niri) |
| `Option ,` / `Option .` (ou `←` `→`) | foco pra coluna da esquerda / direita, a fita rola junto |
| `Option Shift ,` / `Option Shift .` (ou `Option Shift ←` `→`) | troca a coluna focada de lugar com a vizinha da esquerda / direita |
| `Option Cmd ,` / `Option Cmd .` | empilha a focada na coluna da esquerda (embaixo) / da direita (em cima); empilhada, separa pra uma coluna só dela daquele lado |
| `Option Cmd +` / `Option Cmd -` | altura da focada numa coluna empilhada: pula entre 1/3, 1/2 e 2/3 |
| `Option ↑` / `Option ↓` | foco na janela de cima / de baixo da coluna (fora de uma coluna empilhada, a tecla vai pro app) |
| `Option F` | coluna em largura total; de novo volta à largura anterior |
| `Option D` | mostra a mesa: as janelas saem pela borda mais próxima, sem os ícones da mesa; de novo voltam |
| `Option V` | histórico do que foi copiado: clique ou `↩` cola, digitar pesquisa, o alfinete fixa (seção "Histórico do clipboard") |
| `Option S` | print: congela a tela, arrastar escolhe a área, desenhar, `⌘C` copia, `⌘S` salva, `Esc` cancela (seção "Print") |
| `Option 1` a `Option 4` (e a letra de cada workspace) | vai pro workspace; a fita atual sai de lado e a dele entra |
| `Option Shift 1` a `4` (idem) | manda a janela focada pra esse workspace |

Segurar a tecla repete (só o resize, o foco e mover coluna; empilhar não, senão ia e voltava). Janela nova entra à direita da focada com 50% da largura; nenhuma outra encolhe. Esses são os atalhos padrão; todos podem ser trocados (abaixo).

Config opcional em `~/.config/niri-os/config.json` (todas as chaves opcionais). O painel grava nele, e salvar o arquivo à mão também aplica na hora:

```json
{ "gap": 12, "topPadding": 0, "bottomPadding": 0, "defaultColumnWidth": 0.5,
  "widthPresets": [0.333, 0.5, 0.667, 1], "heightPresets": [0.333, 0.5, 0.667], "resizeStyle": "ghost", "stiffness": 800,
  "shortcuts": { "grow": ["option+=", "ctrl+option+up"], "toggleFullWidth": [] },
  "borderColor": "#BE00F9", "borderWidth": 3,
  "wallpaper": "~/Pictures/fundo.jpg", "wallpaperEffect": "dither",
  "workspaces": ["1", "2", { "name": "T", "apps": ["com.github.wez.wezterm"], "open": "WezTerm" }],
  "onWorkspaceChange": "sketchybar --trigger niri_workspace_change FOCUSED_WORKSPACE=$NIRI_WORKSPACE",
  "features": { "clipboard": false } }
```

`shortcuts`: ações `grow`, `shrink`, `growHeight`, `shrinkHeight`, `focusLeft`, `focusRight`, `focusUp`, `focusDown`, `moveColumnLeft`, `moveColumnRight`, `consumeOrExpelLeft`, `consumeOrExpelRight`, `toggleFullWidth`, `toggleDesktop`, `clipboard`, `screenshot`. Uma ação no arquivo troca a lista inteira dela (as outras ficam no padrão); `[]` desliga. Atalho = modificadores (`ctrl`, `option`, `shift`, `cmd`) + tecla: letra, número, símbolo (`` = - , . / ; ' [ ] \ ` ``), `left` `right` `up` `down`, `space`, `return`, `tab`, `escape`, `delete`, `home` `end` `pageup` `pagedown`, `f1` a `f12`, `keypadplus` `keypadminus`, ou `key<código>`. A tecla vale pela posição (igual em US e ABNT2). Com Shift apertado e sem atalho próprio com Shift, vale o mesmo sem ele (`Option Shift =` = `Option =`). O mesmo atalho em duas ações: vale a primeira, com aviso. `borderColor`: `#RRGGBB`, `#RRGGBBAA` ou `accent` (cor de destaque do sistema, o padrão); `borderWidth` em pt (padrão 3; 0 tira a borda). É a borda da janela focada, que também contorna o vidro do resize (seção "Borda da janela focada"); os nomes de antes, `ghostBorderColor` e `ghostBorderWidth`, ainda valem. `wallpaper`: imagem ou vídeo (`.mp4`, `.mov`, `.m4v`); sem a chave, o niri-os não mexe no papel de parede do macOS (e devolve o de antes, se o atual era dele). `wallpaperEffect`: `none` (padrão), `dither`, `halftone`, `scanlines` ou `ascii`, só pra imagem. Detalhes em "Mesa e papel de parede". `workspaces` e `onWorkspaceChange`: seção "Workspaces". `screenshotFolder`: onde o `⌘S` do print salva (padrão: a pasta do print do macOS). `features`: `tiling`, `border`, `clipboard`, `screenshot` e `wallpaper`, `false` desliga (seção "Recursos que dá pra desligar").

Ao recarregar: atalhos, borda, papel de parede e regras de app valem na hora; a lista de workspaces também (as janelas de um que saiu da lista vão pro atual); `gap`, margens, `defaultColumnWidth`, `stiffness` e `centerFocusedColumn` animam as janelas pro lugar novo (nada pula); `widthPresets`, `heightPresets` e `widthStep` valem na próxima tecla; `resizeStyle` e `axTimeout` só ao reiniciar. Arquivo com JSON inválido: ao abrir, usa os padrões; ao recarregar, continua com o que estava até o arquivo voltar a ser válido. Nos dois casos avisa no log e no painel, e o painel não grava por cima (perderia o que foi escrito à mão).

`topPadding` serve pra SketchyBar. `stiffness` maior = animação mais rápida (800 ≈ 0,35 s, igual ao niri). `widthPresets: []` volta pro passo fixo de `widthStep` (padrão 0.1). `heightPresets`: as alturas do `Option Cmd +/-`, frações entre 0 e 1 da altura da coluna. `resizeStyle` é como o `Option +/-` anima: `ghost` (padrão, vidro fosco no lugar da janela, abaixo), `photos` (fotos das janelas, abaixo; precisa da permissão de Gravação de Tela pro terminal, e sem ela vira `live`) ou `live` (as janelas reais, frame a frame).

## Como funciona

- **Layout** (`Sources/NiriCore`): fita de colunas + viewport, sem AppKit. A largura e a rolagem são molas criticamente amortecidas (modelo do niri). Trocar o alvo no meio preserva a velocidade, então segurar a tecla não dá tranco.
- **Uma fila por app** (`AppWorker`): toda chamada de Acessibilidade pra um app passa pela fila dele. A animação roda a 120 Hz (display link). Se o app ainda está ocupado com o frame anterior, os intermediários são descartados e ele pula pro mais recente. App lento só atrasa as próprias janelas.
- **Janela fora da tela**: o macOS puxa de volta pra 40 pt visíveis qualquer janela 100% fora da tela, mas aceita 1 pt. Então janela fora da viewport fica "estacionada" na borda com 1 pt visível, dentro da margem. O OmniWM faz o mesmo (as janelas dele ficam em x=1727). Desde 2026-10-16 toda estacionada fica na borda direita, mesmo a que o layout põe na esquerda: lá a posição não depende da largura (na esquerda é x = 1 - largura, e com a largura velha sobrava um pedaço na tela). Quando uma estacionada volta pela esquerda, o pulo de uma fatia de 1 pt pra outra não aparece. Um teste no mesmo dia pareceu mostrar o WhatsApp saindo sozinho da borda direita (posto em x = 1727, em menos de 1 s estava em x = 0); o log mostrou que quem pôs ele em x = 0 foi a conferência do próprio niri-os, por causa do bug do deslocamento da troca de workspace (seção "Workspaces"). Nenhum app se mexeu sozinho.
- **Foco**: `_SLPSSetFrontProcessWithOptions` + evento de "make key" via `SLPSPostEventRecordTo` (SkyLight, funciona com SIP ligado, mesma técnica do yabai/AltTab) + `AXRaise`. Pedidos de foco passam por uma fila única e só o último vale. Eco de pedidos antigos é ignorado por 0,5 s, senão o layout "voltaria sozinho".
- **Atalhos**: CGEventTap numa thread própria (engole a tecla, então o app não recebe "≠" nem "ƒ").
- **Transição do resize** (`TransitionOverlay`): durante o `Option +/-`, quem anima na tela são fotos, desenhadas por nós a 120 Hz; as janelas reais vão direto pro lugar final por baixo, uma vez só. Detalhes na seção "Apps lentos".
- **Estabilidade**: app que não responde (timeout) é diferente de app sem janela. Timeout não tira janela da fita. Depois de cada animação, as janelas são conferidas e devolvidas ao lugar se o usuário ou o app as moveu.

## Medições (MacBook, macOS 26.5, painéis de teste)

| | |
|---|---|
| `setPosition` / `setSize` via AX | 0,12 ms / 0,40 ms por chamada (janela simples) |
| 1ª chamada AX a um app / seguintes | 9 a 36 ms / 0,2 ms |
| resize e rolagem | ~325 ms, 40 frames a 120 Hz, todos aplicados |
| maior intervalo entre frames | 10 a 17 ms (no máximo 1 frame de 120 Hz pulado) |
| sobreposição entre janelas do mesmo app | 0 frames |

Com `-v`, cada animação imprime frames aplicados, custo por frame, maior intervalo e frames com sobreposição por app. É assim que a gente mede com os seus apps de verdade.

## Apps lentos (medido com o WhatsApp, 2026-10-15)

O WhatsApp pro Mac é Catalyst (app de iPad) e é o pior caso medido até agora. Tudo abaixo com o WhatsApp 26.35.74.

| | WhatsApp | Relógio (Catalyst leve) |
|---|---|---|
| `setSize` via AX (síncrono: volta já aplicado) | 115 a 160 ms | 5 a 8 ms |
| `setPosition` via AX | 0,1 a 0,2 ms | 0,3 ms |
| sem responder AX ao ganhar foco: setFront + makeKey + AXRaise | 67 a 84 ms (dois blocos: ~20 ms e ~65 ms) | |
| idem, só setFront | 24 a 38 ms (um bloco) | |
| sem responder AX ao perder foco | ~20 a 30 ms (até ~90 se tinha ganhado com makeKey) | |
| esconder/mostrar a janela (sem trocar foco) | 2 a 21 ms, sem pico | |

Mudar só a altura custa o mesmo que a largura: é o app refazendo o layout inteiro a cada resize. O `AXEnhancedUserInterface` dele já estava desligado. Com o app na frente ou não, o custo é o mesmo. Tentei medir o live resize (arrastar a borda com mouse sintético) e o arraste não pegou a borda; ficou sem dado.

O que o niri-os faz com isso:

- **Foco sem makeKey quando não precisa.** Se a janela alvo já é a que o app considera focada (sabido pelos eventos de foco, sem leitura nova), basta o setFront: o estado AX fica igual (app na frente, janela principal, campo de texto focado). O makeKey a mais fazia o WhatsApp redesenhar duas vezes. Medido no niri-os com `-v`: maior intervalo do WhatsApp nas trocas de foco caiu de 49 a 76 ms pra 9 a 37 ms; na gravação do WindowServer, a sobreposição com a vizinha caiu de até ~1100 pt pra até ~340 pt.
- **Testado e revertido: resize uma vez por ação pra app lento** (`setSize` > 25 ms). A janela ficava com a menor largura entre a atual e a final durante a animação e só esticava no fim; ao encolher, a fita esperava o app encolher primeiro. Na gravação: de 5 a 7 larguras intermediárias por ação pra 1, e sobreposição no encolher de ~65 pt pra 0 a 10 pt. Mas no uso ficou pior: abre buraco (papel de parede) por ~300 a 450 ms, e o resize de ~150 ms que ficava pro fim travava a fila do app quando a próxima tecla vinha logo (65 a 90 ms de intervalo com `Option - / +` repetido). Centralizar a janela travada também foi testado: encolher em dois passos e tremida de 1 pt com largura ímpar.

- **Resize por fotos** (seção abaixo): brigar com o ritmo de cada app não resolve, então durante o resize quem anima são fotos e o app recebe só o tamanho final.
- **Spam de `< >` só rola; o app onde parar é ativado quando a fita assenta** (padrão desde 2026-10-15). Desde 2026-10-16 vale pra toda tecla, inclusive a 1ª com a fita parada (abaixo, "Foco no fim da animação"). Antes, cada app atravessado era ativado e desativado, redesenhava e parava de responder AX: num spam de 6 s, maior intervalo Arc 403 ms, outro app 326, WhatsApp 208, Zed 73 (a main em 8,7). Depois, em 10 spams de 1 a 5 s: todos ≤ ~21 ms, menos o WezTerm (até 37). Custo: depois de um spam, o teclado só muda de janela ~0,4 s depois da última tecla.
- **Gravando com o OBS (janela dele na fita), ainda trava:** OBS, Spotify e WezTerm batem no timeout de 200 ms; Arc e outro navegador Chromium ~53 ms. O OBS responde AX a 7,6 ms/frame em média (até 35). Falta separar a janela do OBS na fita da carga da gravação.
- **Experimento, removido em 2026-10-16: `NIRI_FOCUS_DELAY=45`** (ms). Ao perder foco o WhatsApp fica ~25 a 45 ms sem responder (redesenho de ativo pra inativo). Começando a rolagem 45 ms depois da tecla, ele passou a andar junto com as outras (atraso de 4 a 14 ms em vez de até 72). Não resolve o desencontro de ~1 frame entre apps na rolagem (90 e 130 ms também não). Saiu porque o foco agora vem no fim da animação.
- **Foco no fim da animação (2026-10-16).** No uso, trocando de workspace com a ativação no começo: Arc parado 208 ms ao perder o foco (duas vezes), WhatsApp 73 ms, e a main do niri-os perdendo um frame (21 ms) em 8 de 40 animações, todas com um app sendo ativado no começo (nos painéis, sem ativação, 8,4 ms). Então todo foco que o niri-os pede (`< >`, workspace, mandar janela, a vizinha de uma janela que fechou) espera duas coisas: toda mola a menos de 3 pt do fim (~0,3 s depois da tecla; assentar de vez leva ~0,4) e os modificadores do atalho soltos. Navegando com o Option seguro, nenhum app atravessado é ativado. Se o app travar redesenhando depois disso, a janela dele para a ≤ 3 pt do lugar. Custo: o teclado só chega na janela nova ~0,3 s depois da tecla; o que for digitado antes vai pro app de antes.

### SkyLight em janela de outro app, com SIP ligado (2026-10-15)

Testado numa janela do WezTerm, conferindo pelo WindowServer (camada na lista de janelas) e por print de tela, não pelo código de retorno:

| função | retorno | efeito real |
|---|---|---|
| `SLSSetWindowAlpha` | 0 (ok) | nenhum (alpha continua 1) |
| `SLSSetWindowLevel` | 0 (ok), e a leitura pela mesma conexão volta o valor novo | nenhum (a lista continua com camada 0) |
| `SLSSetWindowTransform` | 0 (ok) | nenhum (a tela não muda) |
| `SLSOrderWindow` | 1000 (erro) | nenhum |
| `SLSHWCaptureWindowList` com opção 1<<15 | ok | foto da janela inteira, até fora da tela, em 10 a 60 ms |

Ou seja: dá pra fotografar qualquer janela, mas não dá pra esconder, mover ou transformar janela alheia fora do AX. Código de retorno 0 não prova nada.

### Transição do resize por fotos (`TransitionOverlay`, `"resizeStyle": "photos"`)

Nenhum app acompanha uma animação de resize (o WhatsApp faz ~7 tamanhos por segundo, Chromium desenha depois e mostra área em branco, o WezTerm estica o texto antigo). Então, no `Option +/-`, a tela vira nossa, como num compositor:

1. Fotos da janela focada, das visíveis e do papel de parede (`SLSHWCaptureWindowList`, ~10 a 15 ms cada; em paralelo não acelera). Quando o Option desce, já começo a fotografar: se a foto fica pronta antes do `+`/`-`, a camada entra em ~1 ms; senão, ~30 a 70 ms.
2. Uma janela nossa (sempre na tela, vazia quando parada) mostra essas fotos idênticas à tela. 2 frames depois as janelas reais vão pro lugar e tamanho finais, por baixo, na tela (Electron/Chromium continuam desenhando e aceitam o resize).
3. A animação espera o app entregar o tamanho novo, como o niri espera o commit (aqui até 300 ms, o mesmo limite do niri): a janela é fotografada sem parar e só vale a captura igual à anterior (o app terminou de desenhar).
4. A fita anima as fotos. A janela que muda de tamanho já aparece no layout novo, em tamanho real, presa à esquerda: crescendo, a borda direita revela; encolhendo, a sobra à direita tem a cor da borda do app e fecha. Nada estica, nada se mistura. Sombra só do lado de fora (como no macOS) e desfoque atrás de janela translúcida.
5. No fim a imagem é igual ao app real e a camada some com fade de 150 ms.

Atraso até mexer: ~20 a 40 ms em app rápido, ~150 a 250 ms no WhatsApp (o tempo dele redimensionar e redesenhar). Memória: pico de ~28 MB durante a transição; as fotos são soltas no fim. Parado: 13 MB (eram 8,3; a diferença é a janela da camada sempre na tela, porque esconder e mostrar de novo atrasava a foto em ~170 ms). CPU: 0% parado; 27 a 40% durante a transição (as capturas seguidas).

Caminho até aqui, cada passo testado com o usuário e com gravação de tela:
- Esticar só a foto velha: texto deforma.
- Fatias com uma coluna esticada: faixa preta no modo escuro. Cortar ou repetir uma faixa do meio: corta e duplica texto dos balões.
- Fusão velha → nova esticadas (o padrão do niri, `shaders/resize.frag`), com a janela estacionada fora da tela: bom no WhatsApp, mas Electron/Chromium recusam resize fora da tela e param de desenhar (foto preta), e o WezTerm translúcido ficava cinza. Fusão sempre deixa texto fantasma no meio.
- Camada na tela toda com fusão: funciona com qualquer app, mas o fantasma continuou. Trocar no meio esticando: sem fantasma, mas com passos de 1/3 a imagem do meio fica muito esticada. Dissolver a imagem velha no app real no fim: fantasma parado de 150 ms (no Spotify o layout muda muito).
- O WezTerm cinza era a sombra (calculada pelo contorno da foto, aparecia por dentro do fundo translúcido) e as duas camadas translúcidas empilhadas na fusão.

Ferramentas da medição: `--script` agora roda também sem `--pid` (nas janelas de verdade, com foco), que é o único jeito de medir troca de foco. A gravação do que aparece na tela foi feita lendo `CGWindowListCreateDescriptionFromArray` a cada ~1,2 ms (não fala com o app).

### Resize fantasma (`GhostOverlay`, padrão desde 2026-10-15)

Ideia da prévia do Loop (MrKai77/Loop): em vez de fotografar, um vidro fosco nosso (`NSVisualEffectView` `.hudWindow`, com o canto da janela e a borda da janela focada por fora; até 2026-10-16, borda própria e canto fixo de 16 pt) anda no lugar da janela que muda de tamanho.

1. Na tecla, o vidro entra no lugar da janela e ela vai pra fora da tela (1 pt na borda direita). Encolhendo, o tamanho novo é aplicado antes de sair, ainda na tela e por baixo do vidro, porque fora da tela o Electron recusa resize.
2. A fita anima: as vizinhas são as janelas reais (só posição, como no `< >`), e o vidro segue o frame da janela escondida. Outra tecla no meio só muda o alvo da fita.
3. Fita parada e Option solto (ou seguro, sem nenhuma tecla, por 0,5 s): a janela volta no lugar e tamanho finais, por baixo do vidro. Só com a fita parada, apertando `+/-` várias vezes ela parava entre uma tecla e outra e a página aparecia pelo vidro até a tecla seguinte, que veio 320 a 370 ms depois de a fita parar. Só com o Option, quem segura ele depois da tecla esperava ~2,8 s. O vidro só começa a sumir 150 ms depois que o app terminou de redesenhar: captura da janela (não aparece na tela) até ela ter a largura final e ficar 50 ms sem mudar, no máximo 600 ms (vídeo tocando nunca para). Os 150 ms são porque alguns apps ainda se reorganizam depois dos 50 ms parados, e isso aparecia no fade. Aí some em 350 ms, com curva suave no começo e no fim. Sem Gravação de Tela, espera fixa de 300 ms.
4. A conferência pós-animação espera o vidro sumir, senão leria o tamanho velho e mandaria o resize de novo no meio do redesenho.

Primeira versão saía com tempo fixo (100 ms de espera + fade de 200 ms): o usuário achou a saída brusca, dava pra ver a página do Arc se reorganizando e o texto do WezTerm refluindo durante o fade. Com a espera pela captura, num painel de teste que pisca por 300 ms depois de cada resize, o vidro esperou 369 e 380 ms.

Ícone do app no meio do vidro (96 pt, `NSRunningApplication.icon` num `NSImageView` com margens elásticas: o AppKit recentraliza quando o vidro muda de tamanho, sem código por frame). Sai junto com o vidro no fade. A/B nos painéis de teste, 8 resizes, 2 rodadas cada: pico de 15 MB contra 14 MB sem ícone, CPU e maior intervalo entre frames iguais (~16 ms).

Primeira medição (2026-10-15, painéis de teste, 5 resizes seguidos): maior intervalo entre frames de 8,4 a 16,9 ms, CPU ~2,5% durante a animação (as fotos: 27 a 40%), memória 10 MB com pico de 10 MB (as fotos: 13 MB parado e ~28 MB de pico). Começa a mexer na hora da tecla, sem esperar o app. Avaliação do usuário nos apps reais: "melhorou demais, esse é o caminho"; virou o padrão no lugar das fotos.

## Mover coluna (2026-10-16)

`Option Shift ,` / `Option Shift .` (ou `Option Shift ←` `→`): a coluna focada troca de lugar com a vizinha, como o `move-column-left/right` do niri. O foco continua nela; na ponta da fita, nada acontece. Segurar repete. Shift sozinho com a seta não dá: é selecionar texto em todo app. Antes, `Option <` (Shift + `,`) era o mesmo que `Option ,`; agora é mover.

- **Anima como o resize fantasma:** o vidro, com a borda, entra no lugar da janela, que espera fora da tela; a vizinha é a janela real e passa por baixo do vidro. Fita parada e Option solto (ou seguro por 0,5 s sem tecla), a janela volta no lugar novo e o vidro some do mesmo jeito. Com `resizeStyle` `photos` ou `live`, as duas janelas reais deslizam.
- **No `Layout`** (`moveFocusedColumn`): troca as duas colunas e dá a cada uma, como deslocamento animado, o espaço que a outra ocupa (o mesmo de abrir e fechar janela). Nada pula no primeiro frame e as duas deslizam até o lugar novo. Com `centerFocusedColumn: always`, a focada fica parada no meio e a vizinha atravessa por baixo dela; com a fita inteira na tela, as duas andam.
- **Testes** `moveColumnSwapsWithNeighborWithoutJumping` (os 3 modos de centralizar, larguras diferentes: nada pula, em todo frame só as duas se cruzam e as outras continuam a `gap` exato, até a ponta) e `moveColumnMidAnimationDoesNotJump` (a tecla repetindo no meio). Sem o deslocamento, falham com 13 erros.
- **Medido nos painéis de teste** (5 painéis, 14 ações, 2 rodadas): 16 trocas, maior intervalo entre ticks 8,4 a 12,9 ms, com um de 21,3 ms na 2ª animação de uma rodada (1 em ~50 animações; causa não achada, o caminho do vidro é o mesmo do resize); maior intervalo do app 14,5 e 21,3 ms; 0 frames com sobreposição; verificação final "tudo no lugar".

**A janela voltava a andar por baixo do vidro (valia pro resize também).** Quando a fita para, a janela volta (`attach`), e ela só voltava a receber os frames da fita no fim do bloco dela na fila do app. Uma tecla logo depois escondia a janela de novo (`park`), e o bloco atrasado desfazia isso: a janela andava pela fita por baixo do vidro, por cima da vizinha que cruzava. Visto num teste com `grow` e troca 12 ms depois da volta: 18 frames com sobreposição e a borda andando. Agora ela volta pra fita na main, na hora do pedido, e a ordem é a das teclas. A/B com o app atrasando 40 ms o bloco de volta e uma tecla a cada 370 ms (18 trocas, 2 rodadas): sem a correção, 211 a 255 frames com sobreposição e a borda andando em 16 a 18 trocas; com, 0 e 0.

**`CGPreflightScreenCaptureAccess` no começo.** A 1ª chamada custa 29 ms (as seguintes ~10). Era feita na 1ª volta do vidro, na main, e caía no meio da animação seguinte (um tick de 20 a 25 ms trocando sem parar). Agora é feita ao abrir o niri-os.

Ainda não conferido no uso real: os apps de verdade (Discord e WhatsApp no 2), e segurar a tecla com eles.

## Janelas empilhadas (2026-10-16)

Duas ou mais janelas na mesma coluna, uma embaixo da outra (o Discord em cima e o WhatsApp embaixo), como as colunas do niri. A coluna continua sendo uma só na fita: largura, mover, `Option F` e mesa valem pra ela inteira.

- **`Option Cmd ,` / `Option Cmd .`**, o `consume-or-expel-window-left/right` do niri: sozinha, a focada entra na coluna vizinha, embaixo das da esquerda ou em cima das da direita, e a altura fica dividida por igual. A coluna fica com a largura das duas somadas: duas de 1/2 lado a lado viram a tela toda, partida no meio. No niri ela fica com a largura da coluna de destino, e no uso a pilha apareceu estreita no meio da tela. Empilhada, ela sai pra uma coluna só dela daquele lado, e as duas ficam com metade da largura (com o gap, duas de p/2 ocupam exatamente o espaço de uma de p). Uma tecla pra juntar e a mesma pra separar. Não repete segurando (ficaria indo e voltando). Com Cmd porque `Option Cmd ← →` troca de aba no navegador.
- **`Option Cmd +` / `Option Cmd -`**: altura da focada, pulando entre 1/3, 1/2 e 2/3 (`heightPresets`); as outras dividem o resto na proporção que tinham. Só `Cmd +` e `Cmd -` seria o zoom de todo app. Sozinha na coluna, nada muda.
- **`Option ↑` / `Option ↓`**: foco na de cima / de baixo. Cada coluna lembra a sua focada: `Option ←` e volta cai na mesma. Fora de uma coluna empilhada a tecla não é engolida e vai pro app (no editor, sobe e desce parágrafo).
- **Vidro em toda janela que muda de tamanho.** Juntar, separar, mudar a altura, a largura da coluna empilhada, mandar uma empilhada pra outro workspace, fechar ou esconder uma delas: cada janela da tela que vai terminar com outro tamanho espera fora da tela atrás do vidro e volta pronta no fim, como no resize fantasma; as que só andam são as reais. O vidro da focada fica por cima: entrando na coluna vizinha, ela passa por cima das de lá. Encolhendo, o tamanho novo vai antes de sair da tela, agora também na altura.
- **No `Layout`:** a coluna tem uma lista de janelas (`Tile`), cada uma com a parte dela da altura e molas de altura e de deslocamento (x, y, largura). Quem muda de coluna ou de lugar na coluna continua onde estava na tela no primeiro frame e anda até o lugar novo com a mola (`restore`, o mesmo princípio do `offset` das colunas). A altura acumula de cima pra baixo e só arredonda no fim, então entre duas janelas da coluna o espaço é sempre exatamente `gap`, em todo frame do `Option Cmd +/-`.
- **Duas fases, sem uma passar por cima da outra.** Animando tudo junto, a que entrava na coluna atravessava a outra (visto no uso). Juntando, primeiro a altura muda, cada uma ainda na coluna dela; depois as duas alargam, uma em cima e outra embaixo. Separando, ao contrário: primeiro a largura, depois a altura. A segunda fase espera a primeira chegar a 0,7% do caminho (7/ω, 0,25 s com a mola padrão; `Spring.postpone`), então juntar ou separar leva ~0,6 s em vez de ~0,35. Sem as duas fases, o teste de sobreposição frame a frame dá 330 falhas.
- **Altura mínima aprendida**, como a largura: o app que recusa ficar mais baixo (duas leituras iguais, 0,6 s uma da outra) vira o limite dela na coluna, e as outras ficam com o resto. Ninguém é espremido abaixo do limite: se os limites somados não cabem, cada uma fica no dela e a de baixo passa do pé da tela. E não empilha (nem volta pra pilha) quando os limites já conhecidos não cabem juntos. No uso, Discord (500 pt) e WhatsApp (600 pt, e 970 de largura) não cabem: a coluna tem 1048 pt de altura útil (1084 visíveis, menos 3 gaps de 12), e 500 + 600 + 12 = 1112. Espremido, o Discord ficava por cima do WhatsApp, e a conferência mandava o tamanho de novo a cada ~0,4 s sem parar (167 correções em 50 s). Agora só anima de novo se o limite mudou.
- **Volta pro mesmo lugar:** fechada no X por app que só esconde (WhatsApp, Discord), minimizada ou em tela cheia, a empilhada volta pra mesma coluna, embaixo da de cima dela (ou em cima da de baixo). O estado salvo guarda a pilha (`stacked`, `share`, `minHeight` em `state.json`); reiniciar volta igual, e os limites aprendidos continuam valendo.
- **Testes** (`NiriCore`): juntar e separar nos dois lados e nos 3 modos de centralizar (nada pula no primeiro frame, ninguém com tamanho negativo, gap exato no fim), `gap` exato em todo frame do `Option Cmd +/-` (inclusive a tecla repetindo no meio), altura mínima, fechar e voltar pra pilha, foco por coluna, estado salvo, mesa com coluna empilhada e mandar empilhada pra outro workspace. Sem o `restore`, 12 falhas.
- **Depois das duas fases e da largura somada** (painéis de teste, 12 ações): maior intervalo entre ticks 8,4 a 14,3 ms, do app até 14,2 ms, 0 frames com sobreposição, verificação "tudo no lugar".
- **Medido nos painéis de teste** (4 painéis, 15 ações: juntar, alturas, foco, largura, mover, separar, juntar à direita, mandar pra outro workspace; 2 rodadas): maior intervalo entre ticks 8,4 a 15,6 ms, do app até 16,1 ms, 0 frames com sobreposição, verificação final "tudo no lugar". Escondendo a de baixo no meio da pilha e mostrando de novo: a de cima cresceu com o vidro e a escondida voltou embaixo dela, com `gap` exato. Memória: 10 MB parado, 0% de CPU; pico de 15 MB com dois vidros.

Validado pelo usuário nos apps reais (2026-10-16): empilhar, separar, altura e as duas fases ("ficou ótimo as animações"), e a recusa quando os mínimos não cabem é o comportamento certo. Ainda não conferido: o `Option ↑ ↓` passando pro app fora da pilha. Visto uma vez e não explicado: logo depois de um reinício, o Discord empilhou com o WhatsApp sem o limite de altura dele (aprendido de novo 2 s depois); os dois limites ficaram salvos.

## Borda da janela focada (2026-10-16)

Como o JankyBorders, mas dentro do niri-os: um contorno em volta da janela focada da fita, com o canto de cada app, que anda junto com a janela. `borderColor` e `borderWidth` no config ou na aba Borda do painel.

Aparece na focada da fita quando o teclado está nela, ou vai estar (foco adiado pro fim da animação). Some com o teclado em outro app (clique na mesa, o painel) ou numa janela de fora da fita (diálogo, ajustes de um app), com a focada em outro Space (tela cheia, outro desktop), com a mesa à mostra, com a janela estacionada, escondida, indo pro Dock ou voltando dele, e durante a transição do resize por fotos (que fotografa a tela).

- **Segue o WindowServer, não o layout.** A janela do app só muda no WindowServer 3 a 9 ms depois de a chamada AX voltar (mediana 4,7 ms, em qualquer fase do vsync; lendo `SLSGetWindowBounds` logo depois do AX: posição velha em 120 de 120). Uma borda no frame calculado (como a do OmniWM) ou na volta do AX andaria na frente da janela. O niri-os pede ao WindowServer os avisos de "mudou de lugar" e "mudou de tamanho" (`SLSRequestNotificationsForWindows`, eventos 806 e 807) só da janela focada, e a cada aviso põe a borda onde o WindowServer diz que a janela está (~0,02 ms, sem falar com o app). Nada roda por frame do nosso lado.
- **Uma camada CA numa janela nossa da tela toda**, no nível 1: por cima da sombra da focada sem precisar reordenar quando o app traz a janela pra frente, e abaixo de painel flutuante, menu, Dock e do vidro do resize. A camada só tem contorno (o CA desenha, sem bitmap): mudar de tamanho não redesenha nada. Posição, tamanho e mostrar/esconder vão na mesma transação, com flush: 0,014 ms, e trocar de janela não mostra 1 frame com o tamanho velho.
- **Medido na tela** (ScreenCaptureKit a 120 fps numa linha da tela, janela andando 5 pt por frame): camada CA, 98 a 100% dos frames com a borda no lugar; uma janela do tamanho da borda movida com `SLSMoveWindow`, 97,6 a 100%; movida pelo AppKit (`setFrameOrigin` + flush), ~50% (metade 1 frame atrás) e 0,3 ms (até 2,4) na main. A primeira versão mudava o tamanho da janela da borda pelo AppKit: até 5,7 ms na main num aviso. No niri-os de teste (4 janelas, 13 ações: resize, mesa, mandar janela, workspaces, foco), 99,6% dos frames nas três primeiras rodadas (1 frame fora em ~272) e 100% nas duas últimas (563 e 565 frames); só foco e rolagem, 100%. Custo por aviso no niri-os: até 0,16 ms.
- **Canto:** o WindowServer informa o raio de cada janela (`SLSWindowQueryWindows` + `SLSWindowIteratorGetCornerRadii`, a mesma função que o JankyBorders 1.9 usa: 0,2 ms pra 9 janelas, sem Gravação de Tela). No macOS 26: Arc, Discord e Spotify 16, WhatsApp 26, outro navegador Chromium 20, Zed e outro app 12, WezTerm 0. A curva é a contínua do macOS 26: o perfil do canto do Arc, linha a linha, bate com `cornerCurve = .continuous` do CA, não com o circular. A borda é concêntrica com o canto da janela e entra 1 pt nela (o resto da espessura fica por fora), como a do JankyBorders: cobre o antialiasing do canto e o contorno fino do macOS. Encostando só por fora, sobrava um fio claro de 1 a 2 px na curva do WezTerm (visto pelo usuário; o contorno de dentro de uma borda CA arredondada fica ~1 px mais pra fora que a curva da janela). Com o 1 pt, conferido na foto ampliada dos dois cantos de cima do WezTerm: nenhum pixel claro entre a borda e o miolo. O vidro do resize faz igual, e o desfoque dele começa 1 pt pra dentro, senão cobria esse 1 pt da borda durante o fade.
- **Canto que o app desenha:** o WezTerm do usuário (`window_decorations = "RESIZE"`) é uma janela quadrada (raio 0) com fundo translúcido, e desenha por dentro um miolo opaco com canto de ~10 pt. A borda no quadrado deixava a quina translúcida entre ela e o canto que aparece (visto pelo usuário). No código do JankyBorders 1.9 (`windows.c`), raio 0 vira 9 pt fixo, que é perto do canto do WezTerm (~9,5 pt pela diagonal do miolo na tela). Então, pra janela com raio 0, depois que a animação assenta, uma foto de 48 pt do canto de cima, só da janela (`CGWindowListCreateImage`, 10 a 35 ms, fora da main): a área de fora do canto (alpha abaixo de 85% do de dentro) dá o raio, calibrado com o canto contínuo do CA (área ≈ 0,25 R²). No Arc dá 17 pt (o WindowServer diz 16); numa janela de teste igual à do WezTerm, com miolo de 10 pt, 9,8 pt. Uma vez por janela; estacionada a foto vem vazia. Antes de medir, e sem Gravação de Tela, vale o palpite do JankyBorders, 9 pt. O vidro do resize usa o mesmo raio. No WezTerm do usuário a medição dá 7,7 pt; com o 1 pt pra dentro, o canto fica limpo.
- **Janela escondida no X** (WhatsApp, Discord: o app não fecha, só esconde): ela continua existindo no WindowServer, com o mesmo frame, e a borda ficava sozinha no lugar dela (visto pelo usuário). Agora o aviso 816 ("saiu da tela") esconde a borda. E a fita também tinha um buraco: a janela some da lista do app mas continua "no Space 1" (medido), e o niri-os achava que ela estava em outro desktop. Agora, com o 816 e `SLSWindowIsOrderedIn` dizendo que ela está fora da tela (os dois sinais, pra não repetir o bug de tirar janela ao trocar de Space), ela sai da fita e guarda o lugar, como a minimizada: reaberta, volta entre as mesmas vizinhas. O aviso vem de todas as janelas da fita, não só da focada: o app passa o foco pra outra janela antes de esconder a fechada (medido).
- **Minimizar:** o frame no WindowServer não muda durante a animação de ir pro Dock, e os avisos com o número da janela (816, 815 e o da Acessibilidade) só chegam no fim, ~550 ms depois. Mas o evento 1327 ("animação começou", sem dizer a janela) chega aos ~30 ms, e as tags da janela já mudaram (1 << 60 aos 24 ms; 1 << 34 enquanto anima, também voltando do Dock). Então no 1327 e no 1328 (fim) a borda confere as tags da janela dela. Gravando a tela: a borda some 35 ms depois do pedido de minimizar (antes ficava ~550 ms parada no lugar), e voltando do Dock só aparece quando a janela chega.
- **Vidro do resize:** tem o canto da janela e a mesma borda, por fora. Quando a janela volta por baixo do vidro, a borda dela aparece no mesmo lugar e a do vidro some no mesmo commit do CA (nunca as duas, nunca nenhuma). Sem essa troca, uma animação começando durante o fade mostrava a borda do vidro, que segue o frame calculado, até ~90 pt na frente da janela.
- Memória (modo de teste, mesmas condições): 11,0 a 11,3 MB parado contra 10,8 sem a borda; pico 13,0 contra 12,7. CPU parado igual (0 a 1,4%, as duas).

Testado e descartado:
- **Prender a borda à janela do app pelo grupo de movimento do WindowServer** (`SLSAddWindowToWindowMovementGroup`): retorna 0, mas a nossa janela não anda junto (nas duas ordens dos argumentos). Entre duas janelas nossas funciona, e só quando quem move usa `SLSMoveWindowWithGroup`; o AppKit move a janela sem ele.
- `SLSCopyWindowCornerMask` volta nil pra janela de outro app.

Ainda não conferido no uso real: Mission Control (a janela da borda é `.transient`, que o macOS esconde no Exposé), troca de Space com gesto (a borda some só quando a troca termina) e trocar a cor de destaque do sistema com o niri-os aberto (a borda pega a nova ao recarregar o config).

## Barra de menu e painel de configurações (2026-10-15)

Ícone na barra (três colunas, a do meio maior: a fita com a focada no centro). Clique esquerdo ou direito abre o painel, com uma aba por assunto na barra de ferramentas, como os Ajustes dos apps do Mac (desde 2026-10-16; antes era uma página só, com texto explicando cada parte). A janela muda de altura com a aba e abre na última usada.

- **Recursos:** um botão por recurso que dá pra desligar (seção "Recursos que dá pra desligar"). A aba de um recurso desligado fica cinza, com o aviso em cima.
- **Atalhos:** gravar um novo com `+` (Esc cancela; sem ⌃ ⌥ ⌘ a tecla avisa "Use ⌃, ⌥ ou ⌘"), remover com o x no canto da tecla, voltar ao padrão.
- **Workspaces:** a lista na ordem da tela, com os ícones dos apps de cada um. `+` cria (o próximo número livre), `−` apaga (as janelas dele vão pro workspace da tela), arrastar muda a ordem. À direita, o escolhido: nome, os dois atalhos, os apps que abrem nele e o app que abre quando ele está vazio (`open`).
- **Papel de parede:** prévia, arquivo e efeito.
- **Borda:** cor e espessura da borda da janela focada (também em volta do vidro do resize), com prévia (o mesmo vidro do resize, sobre o papel de parede).
- **Geral:** o arquivo (abrir, mostrar no Finder, recarregar) e sair.
- Problema no config (JSON inválido, atalho repetido) aparece embaixo de qualquer aba.

Workspaces pelo painel:

- **Renomear leva as janelas junto.** Nome novo no lugar de um que saiu da lista é o mesmo workspace renomeado (`Workspaces.setNames`; vale também editando o arquivo à mão). O nome só vale no Enter ou ao sair do campo: cada letra seria um workspace novo. Janela minimizada ou em tela cheia guardada com o nome velho volta pro novo.
- **Atalho no padrão segue o nome:** renomear 5 pra W troca ⌥5 por ⌥W. Padrão que já é de outra ação fica de fora (um workspace D não pega o ⌥D, que é da mesa).
- **Adicionar app:** os apps abertos num menu, com o workspace onde cada um abre hoje ("Discord (no 2)"), porque escolher tira de lá; ou qualquer app pelo Finder ("Outro…"). Grava o bundle id. Padrão com `*` só pelo arquivo; o painel mostra o ícone do primeiro app de /Applications que bate.
- **O arquivo fica como a pessoa escreveu:** workspace sem nada além do padrão vai só com o nome (`"Y"`), e criar e apagar um workspace deixou o config de uso idêntico ao original (conferido com `diff`).

Memória do painel (release, config de uso): 34 MB aberto em Atalhos, 39 MB em Workspaces, 74 MB com pico de 285 MB depois de passar pelas 5 abas (a página única era ~50 MB com pico de ~260). Cada aba só carrega quando é aberta, e o processo sai ao fechar.

Como funciona:

- **O arquivo é a única fonte.** O painel grava só o que difere do padrão, mantendo as outras chaves. O niri-os vigia a pasta por FSEvents (eventos por arquivo, pega gravação atômica de editor e link simbólico de dotfiles) e recarrega quando o conteúdo muda. Sem polling. Do clique no painel até o niri-os aplicar: ~170 ms (150 ms de espera pra juntar arraste de cor, mais o FSEvents).
- **O painel é outro processo** (`niri-os --settings`), aberto pelo ícone e encerrado quando a janela fecha. Conversa com o niri-os pelo arquivo e por linhas no stdout: `pause`/`resume` (atalhos pausados enquanto grava um novo: o tap HID pegaria a tecla antes do painel), `front <janela>`, `reload` e `quit`. Se o painel cair, o niri-os despausa sozinho.
- **Foco do painel:** aberto por um processo de fundo, o `NSApp.activate()` do macOS 14+ recusa (o painel abria atrás do app da frente). O pedido de frente do SkyLight feito pelo próprio painel funcionou em 1 de 2 aberturas; feito pelo niri-os (o mesmo do foco da fita), em 5 de 5, e o clique com o painel aberto atrás de outro app traz ele de volta.

Memória (physical footprint, modo de teste, sem apps na fita):

| | niri-os | painel |
|---|---|---|
| sem ícone (antes) | 9,8 a 9,9 MB | |
| ícone na barra | 11,2 a 11,4 MB (o item custa 1,4 MB; desenhado à mão porque o símbolo SF somava 0,6) | |
| painel aberto | igual | ~50 MB, pico ~260 MB ao abrir |
| depois de 5 aberturas | +0,1 a 0,2 MB | 0 (o processo sai) |

Testado e descartado:
- **Painel dentro do niri-os:** abrir subia de 12 pra 50 MB, com pico de 262 MB, e fechar só voltava pra 44 MB; cada abrir e fechar deixava ~5 MB a mais. Medido por partes: janela AppKit vazia +7 MB que não voltam, SwiftUI vazio +8, o `Form` +25 (e o pico de ~250), a prévia +12 (miniatura de 1000 px do papel de parede 4K: pico de +21, fica +7 a 9).
- **Menu no ícone:** abrir um `NSMenu` uma vez custa 3,3 MB que não voltam. Clique abre o painel direto, e recarregar e sair ficaram dentro dele.

Pausa dos atalhos conferida com `⌥G` (modificador de atalho, sem ação): gravando, a tecla chegou ao painel e o log `-v` do niri-os não registrou nada.

## Recursos que dá pra desligar (2026-10-16)

Aba Recursos do painel, ou `"features": { "border": false }` no config: `tiling` (a fita de janelas, com os workspaces), `border` (a borda da janela focada, e com ela a do vidro do resize), `clipboard` (o histórico do `Option V`) e `wallpaper` (o papel de parede do niri-os). A borda precisa da fita: ela segue a janela focada que a fita informa, e sem a fita teria que descobrir o foco lendo os apps pela Acessibilidade (quem quer só a borda tem o JankyBorders). Borda, histórico e papel de parede valem na hora, sem reiniciar. Desligado, o recurso não existe no niri-os: a borda tira a janela dela, o histórico tira o monitor de teclado e mouse, e o papel de parede devolve o do macOS (o processo dele restaura e sai). O atalho do recurso desligado sai do tap de teclado e passa pro app. O que a pessoa escolheu (cor, arquivo, efeito, o que foi copiado) fica guardado, e religar volta igual. O painel fica com o config inteiro e o niri-os usa a versão sem os recursos desligados (`Config.active`), pra o painel não gravar espessura 0 ou papel de parede vazio por cima do que a pessoa escolheu.

Medido:

- **Modo de teste, ligado contra desligado desde a abertura:** 9,95 contra 9,73 MB, e uma janela do niri-os a menos (a da borda). O script `right,grow,shrink,left,full,full,clipboard,wait` deu "tudo no lugar" nos dois, com maior intervalo entre frames de 15,2 ms ligado e 8,4 ms desligado. Com o histórico desligado, a pasta dele nem é criada.
- **Ligar e desligar com o app aberto (niri-os de uso, 11 janelas):** 60 voltas de borda ou histórico, uma a cada 0,6 s (o papel de parede ainda não foi medido assim). Depois de um salto de ~1,5 MB nas primeiras voltas (memória que o `malloc` guarda pra reusar), fica entre 13,4 e 13,9 MB, sem crescer. CPU parado: 0%.
- **A janela da borda criada antes do run loop não saía da memória.** Desligada, ela saía da tela, mas o `NSPanel` continuava vivo: o `heap` mostrava 0 `FocusBorder` e um `NSPanel` a mais. Não resolveu nem `autoreleasepool` em volta da abertura, nem `close()` com `isReleasedWhenClosed = false`. As bordas criadas com o app já aberto eram liberadas. A borda agora nasce no `finishStartup`, que já roda dentro do run loop (antes dele não tem janela na fita pra ela seguir), e aí sai da memória ao desligar.
- **Os avisos do WindowServer não dependem mais da borda.** O registro deles (`Private.watch`) ficava dentro da atualização da borda, que saía cedo sem ela. Sem os avisos, a fita deixaria de ver a janela fechada no X por app que só esconde (WhatsApp, Discord).

### A fita (`tiling`)

Ligar ou desligar a fita reinicia o niri-os: abre um processo novo do mesmo executável, com os mesmos argumentos e o mesmo log, e o velho sai (`Settings.restart`). Montar e desmontar a fita com o app aberto teria que desfazer as filas por app, os observadores, o display link e as janelas nossas, e é desse tipo de sobra que nasce estado que discorda do layout. Reiniciando, são dois caminhos que já existiam: desligar é o `Ctrl+C` (guarda o estado e devolve as janelas pra tela em cascata, as de todos os workspaces) e ligar é a abertura (monta a fita do `state.json`: as janelas que continuam abertas voltam pro workspace, a ordem e a largura de antes). O processo novo só herda o stdout e o stderr: o pipe do papel de parede fecha quando o velho sai, ele vê o fim do stdin e sai, e o novo abre outro. O painel aberto é fechado e abre de novo no processo novo (`NIRI_OPEN_SETTINGS`), na mesma aba.

A primeira versão usava `exec` (o mesmo pid). O ícone ia pra fora da barra de menu (a Acessibilidade dava (7, 1105), contra (1022, 4,5) antes) e não voltava, nem tirando o item da barra antes do `exec`, nem esperando 0,3 s depois de tirar. Com pid novo, o ícone ficou no lugar em 6 reinícios seguidos.

Sem a fita, o niri-os não usa Acessibilidade, display link nem janela nossa: ficam o ícone, o tap de teclado (só com o atalho do histórico; os da fita passam pros apps), o histórico e o papel de parede. O `state.json` não é gravado, pra fita voltar como estava. O vídeo do papel de parede fica parado no quadro em que está: sem a fita, o niri-os não sabe quando a mesa está à mostra. `--workspace` e `onWorkspaceChange` não fazem nada.

Medido na instância de teste (`--pid` com dois painéis e `NIRI_CONFIG`, que no teste também recarrega):

- **Do pedido ao processo novo pronto:** 49 a 72 ms pra desligar (com a cascata) e 98 a 104 ms pra ligar (com a fita montada).
- **Memória:** 11 MB com a fita, 9,8 MB sem. Sem nenhuma janela do niri-os na tela, contra 2 com a fita (o vidro do resize e a borda).
- **Pelo painel:** clique no botão da fita (pela Acessibilidade), o processo reinicia e o painel abre de novo, com pid novo, na aba Recursos e com a borda cinza. Os painéis de teste vão pra cascata e voltam pra fita nos mesmos lugares.
- **6 reinícios seguidos com o painel aberto:** 2 pipes abertos em todos, um painel só, o ícone no lugar.

Não testado na instância de uso: desligar a fita empilha todas as janelas em cascata.

Achado no teste: gravar o config com `cat >`, que esvazia o arquivo antes de escrever, fazia o niri-os recarregar o arquivo vazio, usar os padrões e voltar aos workspaces 1 a 4. As janelas de T, Y e M foram pro 1, e continuaram lá depois de o arquivo voltar inteiro. Editor que grava sem renomear faz o mesmo. Agora a recarga de um arquivo que não é JSON válido é ignorada (`Config.invalid`), e a gravação que completa o arquivo recarrega. Conferido com `: > config.json` seguido do conteúdo de volta: workspaces iguais.

## Mesa e papel de parede (2026-10-15)

### `Option D`: mostrar a mesa

O "mostrar mesa" do macOS mostra os ícones da mesa mesmo com eles escondidos (`StandardHideDesktopIcons = 1`, o caso aqui). O nosso só tira as janelas da frente: os ícones continuam como o Finder está configurado.

- **Cada janela sai pela borda mais próxima.** Quem tem o meio à esquerda do meio da tela vai pra esquerda; o resto, pra direita. Cada lado anda junto, até a janela dele mais perto do meio encostar na borda com 1 pt (a regra de estacionar de sempre). O gap entre vizinhas do mesmo lado fica exato em todo frame (teste `desktopAnimationKeepsGapsAndNeverOverlaps`).
- **Está no `Layout`** (`showsDesktop` e uma mola de 0 a 1000 milésimos do caminho), não num estado paralelo. Por frame, é uma soma por coluna. Mesma mola do resto: trocar no meio preserva a velocidade.
- **Volta com:** `Option D` de novo; qualquer outro atalho (volta e faz o que pediu: `Option →` volta e já foca a da direita); foco em outra janela (Cmd+Tab, Dock); o app da janela focada ativado de novo pela pessoa; janela nova. Fechar uma janela escondida não traz a fita de volta.
- **Não volta com os avisos de foco da própria janela focada.** A conferência de foco 0,6 s depois de cada pedido manda um, e desfazia o `Option D` apertado logo depois de um `Option →`. App sem janela na fita (Finder com clique na mesa, o painel) também não mexe em nada.

Medido nos painéis de teste (`--script right,desktop,desktop,desktop,right,full,desktop,left,desktop`): cada animação ~390 ms, maior intervalo entre ticks 8,4 a 13,1 ms, maior intervalo por app ≤ 14,3 ms, 0 frames com sobreposição, verificação final "tudo no lugar".

### Papel de parede (`wallpaper`, `wallpaperEffect`)

- **Imagem: vira o papel de parede do próprio macOS** (`NSWorkspace.setDesktopImageURL`). Com efeito, o PNG pronto fica em `~/Library/Application Support/niri-os/wallpaper/<hash>.png` (nome novo a cada mudança: com o mesmo nome o macOS mostra o cache velho). Depois de aplicado custa zero: nenhuma janela nossa, nada na memória do niri-os, e aparece também no Mission Control e na troca de Space. O papel de parede de antes do primeiro nosso fica em `original.txt` e volta quando `wallpaper` sai do config.
- **Efeitos portados do Kinggie** (King Bot v2, `src/kinggie/web/backdrop/treat.ts`), mesmas contas e números, com os testes dele portados (`WallpaperEffectTests`): dither Bayer 4×4 por canal em 4 tons (célula de 3 pt), meio-tom em células de 6 pt com ponto do tamanho do brilho, scanlines (uma linha em três a 0,38, as outras a 1,1) e ASCII (glifos ` .:-=+*#%@` em células de 7×12 pt). Como no Kinggie: uma amostra por célula (a imagem reduzida com filtro bom), o efeito, e cada amostra ampliada sem filtro. Na tela o dither sai em blocos de 6×6 px nítidos (conferido capturando a janela do papel de parede).
- **Vídeo: janela nossa no nível do papel de parede** (-2147483623: acima do papel de parede do Dock, -2147483624, e abaixo da janela da mesa do Finder e da do WindowManager, -2147483603), em loop, sem som, sem impedir a tela de apagar. Toca só com a mesa à mostra (`Option D` ou fita vazia) e com a janela visível (outro Space, app em tela cheia, tela bloqueada ou apagada pausam pelo aviso de oclusão do macOS, sem polling). Parado, fica no quadro onde estava, que é o que aparece nos gaps. O 1º quadro vira o papel de parede do macOS por baixo, que é o que aparece se o niri-os sair.
- **Tudo roda em outro processo** (`niri-os --wallpaper <arquivo> <efeito>`, ou `--wallpaper none` pra devolver o de antes), aberto pelo niri-os só quando o config muda. O de imagem sai sozinho depois de aplicar; o de vídeo recebe `play`/`pause` pelo stdin e sai quando o stdin fecha (o niri-os saiu). Sem `wallpaper` e sem nada pra devolver, nem abre.
- **Painel:** seção "Papel de parede" com escolher/remover arquivo, efeito (nomes e dicas do Kinggie) e prévia. Com efeito, a prévia é o centro da tela em tamanho real: reduzir um dither embaralha os pontos (o moiré que está aberto na prévia do Kinggie).

Medições (MacBook, 1728×1117 pt a 2x, imagem 3840×2160):

| | |
|---|---|
| render de um efeito (ler + efeito + PNG) | 150 a 250 ms |
| PNG gerado | dither 0,3 MB, ASCII 0,7, meio-tom 1,4, scanlines 3,2 |
| pico de memória do render | 124 MB (os 5 efeitos seguidos num processo): por isso fica fora do niri-os |
| processo do vídeo, 4K 60 fps HEVC | parado: 30 MB e 0% de CPU; tocando: 32 MB e 3% |
| niri-os parado, modo de teste, antes / depois | 9,7 a 9,8 MB / 9,8 MB (linkar o AVFoundation não pesa enquanto ninguém usa) |

Ainda não conferido no uso real: a pausa por oclusão (tela cheia, Space, bloqueio), o clique na mesa com o Finder tendo janela na fita, e papel de parede dinâmico ou Aerial como "o de antes" (a API devolve uma URL; se for de um Aerial, pode não voltar igual).

## Workspaces (2026-10-16)

Uma fita por workspace, lado a lado como os Spaces do macOS. Trocar desliza a fita atual pra fora e a nova pra dentro, juntas (a nova encosta na velha) e com a mesma mola do resto (~0,4 s). As outras ficam fora da tela, estacionadas com 1 pt na borda, como as colunas fora da viewport.

**Por que de lado e não de cima pra baixo como no niri** (medido num painel de teste, posição pedida via AX e lida de volta no AX e no WindowServer): em cima o macOS para a janela embaixo da barra de menu (pedido y = -400, real 33); embaixo deixa no mínimo 24 pt à mostra (pedido y = 3117 numa tela de 1117, real 1093). Na horizontal aceita 1 pt (x = -259 com 260 de largura, e x = 1727). Então a vertical deixaria uma faixa de 24 pt de cada workspace no pé da tela.

Config:

```json
"workspaces": [
  { "name": "1", "apps": ["company.thebrowser.Browser"] },
  { "name": "T", "apps": ["com.github.wez.wezterm"], "open": "WezTerm" },
  "Y",
  { "name": "E", "apps": ["Adobe Premiere*"], "key": "ctrl+option+e", "moveKey": [] }
],
"onWorkspaceChange": "sketchybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$NIRI_WORKSPACE"
```

- **A ordem da lista é a ordem na tela:** do 1 pro T, o 1 sai pela esquerda e o T entra pela direita. Sem a chave: 1 a 4. `[]`: um workspace só, sem atalho.
- **Atalhos:** `key` vai pro workspace, `moveKey` manda a janela focada. Sem eles: `Option+<nome>` e `Option+Shift+<nome>`, se o nome for uma tecla (nome como `Web` fica sem atalho padrão). `""` ou `[]` desliga. Mesma checagem de conflito dos outros atalhos: os workspaces perdem pros atalhos fixos (um workspace `D` não pega o `Option D`).
- **`apps`:** janela nova desses apps abre nesse workspace, e não no da tela. Nome como no Dock ou bundle id, sem diferença de maiúscula; terminando em `*` vale como começo do nome (`Adobe Premiere*` pega todas as versões). Vale pra janela nova e, ao abrir o niri-os, pra janela sem workspace salvo; mudar a regra não move janela já aberta.
- **`open`:** o atalho que traz pra esse workspace, com ele vazio, abre esse app (`open -a`). É o `alt-t = ['workspace T', 'exec-and-forget open -a WezTerm']` do AeroSpace, só que sem rodar quando já tem janela.
- **`onWorkspaceChange`:** comando (sh) rodado a cada troca e ao abrir, com o nome em `NIRI_WORKSPACE`. Com o evento `aerospace_workspace_change` acima, uma SketchyBar feita pro AeroSpace funciona sem mudar nada. Pro clique na barra: `niri-os --workspace <nome>` (pede pro niri-os rodando trocar; ~10 ms até chegar, por notificação distribuída do macOS).

Quando a tela vai sozinha pra outro workspace (e quando não vai):

- **Vai:** Cmd+Tab ou Dock pra um app cuja janela está em outro workspace (o app é ativado e a janela vem pra frente); Cmd+` pra uma janela de outro workspace; abrir um app que tem workspace no config (o app está na frente quando a janela aparece); mostrar um app escondido ou tirar do Dock uma janela minimizada de outro workspace.
- **Não vai:** fechar, minimizar ou esconder uma janela (o macOS ativa outro app, e isso não conta por 0,5 s); clicar na mesa (ativa o Finder sem trazer a janela dele pra frente); app em segundo plano abrindo ou focando janela; a conferência de foco 0,6 s depois de cada pedido (é a mesma janela, sem ativação: desfazia a ida pra um workspace vazio).
- **Janela em tela cheia, minimizada ou de app escondido volta pro lugar dela**: o mesmo workspace, entre as mesmas vizinhas, e não o da tela à direita da focada (fica guardado enquanto ela está fora e some quando ela fecha ou o app sai).
- **Workspace vazio não mexe no foco:** o teclado continua no app de antes (a janela dele está escondida no outro workspace). Igual ao AeroSpace.
- **Foco ao trocar:** a focada do workspace novo é ativada no fim da animação, com o Option solto, como no `< >` (seção "Apps lentos", "Foco no fim da animação").
- **Com a mesa à mostra,** trocar leva a fita da mesa direto pra fora (as janelas já estão nas bordas) e o workspace novo entra normal.
- **Mandar janela pra outro workspace:** ela sai da tela na hora e as vizinhas fecham o buraco, como ao fechar. Deslizando até a borda ela passava por cima da vizinha (5 a 6 frames com sobreposição nos painéis de teste). Lá, ela entra à direita da focada e vira a focada.

Estado: o workspace de cada janela vai pro `state.json` e volta igual no reinício; janela sem workspace salvo (inclusive o estado de antes dos workspaces) vai pro do app no config, senão pro 1º. O workspace na tela ao abrir é o da janela focada.

No `Layout`, cada fita ganhou um deslocamento (mola) somado antes de estacionar na borda, e `Workspaces` (NiriCore) só escolhe os alvos: por frame continua sendo a fórmula da mola e a lista de retângulos. Fita parada fora da tela não reenvia nada pro app (a posição não muda). Uma fita do lado errado (um workspace pulado) troca de lado sem animar, então do 1 pro 3 o 2 não atravessa a tela.

Medido nos painéis de teste (`--script right,move:2,move:3,ws:2,ws:3,ws:1,...`, 4 painéis, 5 rodadas de 8 a 15 ações): cada troca ~416 ms e 51 ticks, maior intervalo entre ticks 8,4 a 10,5 ms (um de 21 ms em 40 animações), maior intervalo do app 9 a 11 ms nas primeiras rodadas e 9 a 22 ms nas últimas (com o Mac em uso; o código por frame era o mesmo), 0 frames com sobreposição, verificação final "tudo no lugar" em todas. Memória: 9,4 MB parado (a linha de base era 9,8), pico de 10 MB trocando sem parar; CPU 0% parado e 1 a 2% trocando.

**Janela de outro Space não é janela fechada (2026-10-16).** A Acessibilidade só lista as janelas do Space atual. Indo pra uma tela cheia ou outro desktop, o niri-os achava que uma janela de cada app tinha fechado (visto duas vezes no uso: as 7 sumiram juntas), e na volta elas entravam como novas: à direita da focada, com 50% de largura e no workspace da regra (o Zed voltou do 4 pro 3 sozinho, o WezTerm mudou de tamanho). Agora janela fora da lista do app só sai da fita se o WindowServer diz que ela não está em nenhum Space (`SLSCopySpacesForWindows`, ~0,3 ms, funciona com SIP ligado; janela fechada, ou "fechada" por app que só esconde, vem sem Space). E janela que sai sem fechar volta com a mesma coluna: workspace, vizinhas e largura.

**Coluna vazia na fita (2026-10-17, causa não achada).** No uso, uma coluna sem nada no workspace 3, entre o King Bot e o Kinggie; o `Option <` parava nela. Era a janela 35748: estava no `state.json`, mas não existia no WindowServer nem na lista de Acessibilidade de nenhum app. Reler Finder, Chrome, Kinggie e WezTerm (ativando cada um) não tirou, e com o foco nela a barra de menu seguia no King Bot (o `requestFocus` sai cedo sem `tracked`): o mais provável é que ela estava na fita fora do `tracked`, onde nenhuma limpeza alcança. Não achei no código caminho que faça isso. O que foi medido no caminho:
- Fechar janela no Electron 44 (o do King Bot e do Kinggie): a Acessibilidade solta a janela e manda "destruída" na hora; o WindowServer tira ela da tela ~260 ms depois (aviso 816) e segura a janela viva, fora da tela (no Space ou sem Space), até o app soltar ou sair (mais de 8 s num teste). A releitura logo depois do "destruída" guarda a janela, porque ela ainda está num Space; quem tira é a releitura do 816. Na instância de teste contra um Electron, saiu ~300 ms depois de fechar.
- Id de janela morta na lista do `SLSRequestNotificationsForWindows` não corta os avisos das outras. O primeiro programa de teste dizia que cortava; um teste limpo, repetido, não.
- Dentro do processo do niri-os, a janela de um app morto com `kill -9` ainda responde ao `SLSGetWindowBounds` por mais de 9 s; de outro processo, some em menos de 0,5 s (com ou sem assinatura de avisos, leitura AX, foto ou movimento). Causa não achada; por isso a correção não depende só de "existe".

A correção: no fim de cada animação, sem falar com os apps, a fita confere as janelas no WindowServer. Fora do `tracked`, de app sem worker ou que não existe mais: sai da fita, e o log diz `janela X estava na fita do workspace Y (motivo): saiu`. Fora da tela e não em outro Space: relê o app uma vez, como no aviso 816. Custo com as 10 janelas do uso: mediana 0,115 ms, p95 0,24 ms. Testado com uma cópia que ignora o 816 (3 de 3 saíram pela releitura), uma que deixa a janela fechada na fita fora do `tracked` (3 de 3 saíram, com o log) e a versão real (normal). Se o log aparecer no uso, o motivo e o app dizem por onde ela entrou.

**Largura mínima só com duas leituras (2026-10-16).** Uma leitura só, 150 ms depois de assentar, pegava app assíncrono ainda no tamanho velho, e o limite errado ficava salvo e mudava o tamanho sozinho (Arc 1704, WhatsApp 1643, Discord 1223 pt, depois das janelas entrarem como novas). Agora vale só se a 2ª leitura, 0,6 s depois, confirma, e nunca a largura toda da área.

**Workspace vazio não volta sozinho (2026-10-16).** Duas vezes, 1,5 s depois de ir pro 4 vazio, o app que ficou com o teclado (King Bot, WhatsApp) avisou foco de novo e a tela voltou pro workspace dele. Agora aviso da janela que ficou com o teclado ao ir pra um workspace vazio não troca de workspace; pra voltar, o atalho.

**Conferência pelo WindowServer (com -v).** Depois de cada animação, sem falar com os apps, o niri-os compara onde cada janela está com onde deveria estar e registra no log (`conferência: ...`) janela fora do lugar ou janela de app observado na tela fora da fita (a que está no vidro do resize não conta). É o jeito de pegar janela vazando de outro workspace e app que não entra na fita (Steam).

**Janela de outro workspace vazando (2026-10-16).** O WhatsApp atrás do WezTerm, a aba anônima do Arc por cima de outro workspace e as sobreposições com 6 painéis eram o mesmo bug: o workspace que sai da tela era deslocado em exatamente uma largura de tela, e isso só tira da tela o que estava inteiro nela. No 2 (Discord e WhatsApp, os dois com largura total), o WhatsApp fica logo à direita da tela; com o 2 deslocado uma tela pra esquerda, ele caía em x = 0, dentro da tela, atrás da janela focada, e a conferência pós-animação ainda "corrigia" ele pra lá. A correção: durante a troca, só desliza a coluna que está inteira na tela do workspace; a que está fora da viewport, ou só em parte na tela (uma de 2/3 com uma de 1/2 do lado), fica escondida durante a troca e volta no fim. Testes `offscreenColumnsOfWideStripStayParkedWhileSwitching`, conferidos falhando sem a correção. Nos painéis (6 painéis, 22 ações, 2 rodadas): 0 frames com sobreposição, antes 3 a 54.

**Coluna em parte na tela desliza junto (2026-10-16).** A correção acima escondia na troca a coluna só em parte na tela, e ela voltava de uma vez no fim: no 2, com o Discord de 2/3 focado, o pedaço do WhatsApp na borda direita sumia ao sair e "nascia" depois que o Discord chegava. Agora toda coluna que aparece na tela, mesmo só em parte, desliza com a fita, e a troca anda o bastante pra tirar ela inteira: uma tela, ou mais quando uma coluna passa da borda, sem a fita nova encostar na velha (as duas ficam a um gap uma da outra). No 2 do uso são 2860 pt em vez de 1728, no mesmo tempo de mola; o resto do WhatsApp, que estava fora da tela, aparece passando. A coluna fora da viewport continua estacionada, e fita parada fora da tela fica toda estacionada, mesmo que tenha mudado depois de sair (janela nova, largura aprendida). Testes `partlyVisibleColumnOnTheRightSlidesWithItsStrip` e `...OnTheLeft...` (os dois lados da borda, nos dois sentidos, com gap exato entre a coluna e a vizinha em todo frame); no código anterior a coluna aparecia em 0 ou 1 frame da troca.

Tela cheia nativa (2026-10-16): entrar e sair de tela cheia troca de Space sem nenhum aviso de janela que a gente escute, então a janela que saía da tela cheia ficava solta por cima ou por trás da fita até ser minimizada (o "minimizar conserta" que o usuário viu). Agora a troca de Space relê todos os apps, na hora e 0,5 s depois. Ao entrar em tela cheia, a janela sai da fita sem o foco ir pra vizinha (isso tirava a pessoa do Space da tela cheia), e a conferência pós-animação para de mexer nela (antes mandava o tamanho e a posição da fita pra janela em tela cheia). Ao sair, ela volta pro mesmo workspace, entre as mesmas vizinhas; o mesmo vale pra minimizada e app escondido.

Ainda não conferido no uso real: as regras de foco acima com os apps de verdade (no `--pid` o niri-os não troca o foco), a tela cheia (testar mexeria no Space de quem está usando o Mac), e o clique na mesa com o Finder tendo janela em outro workspace.

## Histórico do clipboard (`Option V`, 2026-10-16)

`Option V` (em `shortcuts`, `clipboard`) abre um painel com o canto no mouse: os últimos 25 textos e imagens copiados e até 10 fixados. Clique ou `↩` cola no app da frente: põe a cópia no clipboard e manda `Cmd V`. Digitar filtra, sem diferença de maiúscula nem de acento, também pelo nome do app de onde veio. `↑ ↓` escolhe, `⌘P` fixa ou desafixa, `⌘⌫` apaga, `Esc` limpa a pesquisa e, vazia, fecha. Clique direito numa imagem abre ela grande no meio da tela escurecida (tamanho real, até 85% da tela); `Esc` ou clique fora fecham só ela. A janela dela não pega o teclado: o painel fecha quando perde o teclado, e o `Esc` chega nele (conferido: o painel continua aberto e com o teclado). Clique fora, `Option V` de novo ou outro atalho do niri-os fecham.

- **Regras** (`ClipboardList`, com testes): os 25 recentes rodam; fixado não conta nos 25 e só sai desafixado ou apagado; copiar de novo o que já está na lista sobe pro topo em vez de duplicar (fixado fica onde está); desafixado vira o recente mais novo. Reiniciar o Mac apaga os recentes e mantém os fixados (como no Windows; pela hora do boot); reiniciar o niri-os mantém tudo.
- **O que entra:** texto com formatação (texto puro, RTF e HTML) ou imagem (PNG, TIFF ou JPEG; só o primeiro que o app der). Fica de fora: o que gerenciador de senha marca como sigiloso (`org.nspasteboard.ConcealedType` e afins; conferido com uma cópia marcada), arquivo copiado no Finder (entraria só o nome) e cópia acima de 50 MB.
- **Como sabe que copiou:** o macOS não avisa. Em vez de consultar o clipboard a cada 0,5 s (o Maccy faz assim), confere o contador dele (`changeCount`, 0,6 µs por leitura) 0,15 s e 0,6 s depois de tecla com Cmd, Return (o `pbcopy` no terminal) ou clique solto (menu Copiar, botão de copiar, o copiar ao selecionar do WezTerm), e ao abrir o painel. Parado não roda nada. Limite: várias cópias seguidas sem tecla nem clique (um script) entram só a última.
- **Três processos.** O niri-os só lê o contador e guarda a lista; nunca toca no conteúdo do clipboard. Cada cópia nova é lida por `niri-os --clipboard-read <id> <contador>`, que grava em disco e sai (5 s sem terminar, o niri-os mata: app de origem travado entregando os dados). O painel é `niri-os --clipboard <x> <y>`: recebe a lista pelo stdin, manda `paste`, `pin`, `unpin` e `delete` pelo stdout, escreve ele mesmo no clipboard ao colar e sai ao fechar.
- **Em disco:** `~/Library/Application Support/niri-os/clipboard/`: `index.json` e uma pasta por cópia, com um arquivo por formato e a miniatura das imagens (feita pelo painel na primeira abertura). Os recentes ficam em disco sem criptografia até o niri-os abrir depois de um reinício do Mac.
- **O painel não ativa o processo dele** (`nonactivatingPanel`, como o Spotlight): conferido com o app da frente igual antes, durante e depois, e o `Cmd V` caindo no app de teste. Vidro do Tahoe (`NSGlassEffectView`), barra de rolagem fina sempre por cima (com mouse ligado o macOS punha a que ocupa 15 pt, e ela cortava os cartões).

Medido (release, modo de teste, painel de teste flutuante):

| | |
|---|---|
| niri-os sem o histórico | 9,7 MB |
| com o histórico, parado | 9,9 a 10,0 MB |
| depois de 3 textos e 1 imagem | 10,2 MB |
| depois de um TIFF de 30 MB, um PNG e um texto | 10,0 a 10,1 MB |
| depois de abrir e fechar o painel 4 vezes | +0,1 MB |
| processo do painel, aberto | 19 MB (89 MB na 1ª abertura depois de copiar um TIFF de 30 MB, fazendo a miniatura) |
| do atalho à janela na tela | 145 a 185 ms |
| do pedido de colar ao `Cmd V` | 10 ms |

Os ~145 ms do painel: 12 ms até o `main`, 48 ms do `NSApplication` conectando ao WindowServer, 16 do `app.run`, 16 criando a janela, 10 montando 5 cartões, 27 pondo na tela. Script de abrir e fechar 6 vezes com cópias no meio: intervalos entre ações de 626 a 634 ms, iguais aos sem o histórico (a main não trava).

Testado e descartado:
- **Painel dentro do niri-os:** abria na hora, mas abrir e fechar levava o niri-os de 10,3 pra 19,2 MB, que não voltavam. O heap vivo crescia só 1,3 MB (fontes, símbolos, caches do Objective-C); o resto era página do malloc fragmentada (`malloc_zone_pressure_relief` não devolve). Antes disso, o fade da janela (`window.animator()`) a segurava viva depois de fechada, com os cartões e as miniaturas.
- **`NSTextField` dentro do niri-os:** +10 MB presos depois da primeira abertura, mesmo sem foco. Um campo próprio com `NSTextInputClient` custava +2 MB e mantinha as teclas mortas (´ e depois a = á, testado no US Internacional). Com o painel em outro processo, voltou o campo do AppKit (cursor, seleção, `Cmd V` na pesquisa).
- **Ler o clipboard no niri-os:** um TIFF de 30 MB deixava o niri-os em 131 MB. Com a fila em `autoreleaseFrequency: .workItem` e um arquivo por formato (sem plist), 71 MB. Num programa à parte: ler 30 MB pelo NSPasteboard custa 89 MB e nada volta (soltar os dados, `pressure relief`, nem o clipboard mudar: fica em 62); pela API do Carbon (`PasteboardCopyItemFlavorData`), 31 MB presos. Num processo que sai, tudo volta.
- **ImageIO no niri-os** pra miniatura na hora da cópia: +3 MB que ficavam. A miniatura passou pro painel.
- **Processo de reserva** (o do painel aberto antes, esperando sem janela): abriria em ~60 ms, mas são 7,9 MB parados o tempo todo. Não feito; fica como opção se os ~150 ms incomodarem.

Limitações: o `Cmd V` mandado usa a posição da tecla V (em Dvorak cairia em outra letra); com a entrada segura do macOS ligada (campo de senha focado), o atalho não chega, como os outros do niri-os.

## Print (`Option S`, 2026-10-17)

`Option S` (em `shortcuts`, `screenshot`) congela a tela do mouse no momento da tecla e abre o editor por cima de tudo: a foto escurecida, arrastar escolhe a área (o tamanho em pixels aparece no canto), as 8 alças mudam o tamanho, arrastar dentro sem ferramenta move, setas movem 1 pt (com Shift, 10), `⌘A` pega a tela toda. A barra embaixo da área (em cima, sem espaço; dentro, sem os dois) tem caneta, linha, seta, retângulo, marca-texto, texto e pixelar (letras P L A R M T X; a mesma de novo solta), 7 cores, desfazer, salvar, copiar e fechar. A rolagem muda a espessura (1 a 20, com um círculo do tamanho no mouse; vale também pro tamanho da letra e do bloco do pixelar), Shift deixa linha e seta em 45° e o retângulo quadrado. `⌘C` ou `↩` copia (PNG), `⌘S` salva em `Screenshot <data> at <hora>.png` e mostra um aviso no canto por 3 s (clique mostra no Finder), `Esc` fecha a caixa de texto e, sem ela, cancela, `⌘Z` / `⌘⇧Z` desfaz e refaz. Sem área escolhida, copiar e salvar valem pra tela toda. Outro app pegando o teclado (`⌘Tab`, Spotlight) cancela, senão a foto ficaria por cima de tudo. `Option S` de novo fecha.

- **A foto sai do niri-os, na hora da tecla** (`Screenshot`): `CGWindowListCreateImage` da tela inteira (por dlsym, como as outras fotos), numa fila própria. Os pixels vão direto da memória da foto pro stdin de `niri-os --screenshot <tela> <pasta>` (`ScreenshotEditor`): uma linha com o formato (largura, altura, bits por cor e por pixel, bytes por linha, `bitmapInfo`) e os 31 MB em seguida. O editor monta a imagem no espaço de cor da tela, então ela aparece na janela sem conversão: conferido pixel a pixel contra a foto salva (abaixo).
- **Com o editor aberto, só o atalho do print é do niri-os** (`HotkeyTap.solo`): os outros vão pro editor (o `Option` + letra digita no texto) e as janelas não andam por baixo da foto. O editor manda `done` pelo stdout quando a foto sai da tela, antes de gerar o PNG e do aviso de salvo: os atalhos voltam na hora.
- **O editor não ativa o processo** (`nonactivatingPanel`, nível `.screenSaver`): o app da frente continua o mesmo e o niri-os não vê troca de foco.
- **Na tela, cada desenho é uma camada** (`CAShapeLayer` pros traços; texto e pixelado viram uma imagem do tamanho deles). O arquivo é desenhado de novo pelo CoreGraphics, com o mesmo caminho de cada traço. O pixelado usa só a foto: o que foi desenhado embaixo dele some junto.
- **O PNG vai com 144 dpi** numa tela Retina, como o print do macOS (num documento, entra no tamanho em que estava na tela). A pasta padrão é a do print do macOS (`defaults read com.apple.screencapture location`; Mesa se nunca mudou), lida a cada config carregada; `screenshotFolder` troca, e o painel tem "Pasta do ⌘S" embaixo do botão do recurso. Erro ao salvar (pasta sem permissão) põe o print no clipboard e avisa.

Medido (release, `--pid` com um pid sem janelas e `--script screenshot`, 5 vezes):

| | |
|---|---|
| da tecla à foto | 12 a 29 ms |
| da tecla aos pixels no editor | 54 a 63 ms |
| da tecla ao editor na tela | 120 a 132 ms |
| niri-os antes / depois de dois prints | 10 MB / 10 MB |
| processo do editor, aberto | 17 MB; 22 MB com 7 desenhos numa área da tela toda |
| tela do editor contra o arquivo salvo (1400x900 px, com 7 desenhos) | 0,049% dos pixels com diferença > 2 (borda dos traços), 2 pixels > 32 |

Testado e descartado:
- **Foto no próprio editor:** um processo novo leva 45 a 85 ms só pra se conectar ao WindowServer, e o frame congelado seria o de 60 a 110 ms depois da tecla.
- **Pixels via `Data`:** `img.dataProvider.data as Data` e `FileHandle.write` deixavam 30 MB presos no niri-os. Escrevendo do ponteiro do `CFData` com `write()`, volta tudo (5,9 MB antes e depois, num programa à parte).
- **Memória compartilhada (`shm_open`):** variádica, o Swift não chama; e um arquivo em disco escreveria 31 MB a cada print. O pipe entrega os 31 MB em ~40 ms.
- **Começar a foto antes de criar o processo:** os dois disputam, e a foto sai em 28 a 53 ms em vez de 12 a 29; o editor, em 153 a 182 ms em vez de 120 a 132.
- **Desenhos numa view (`draw(_:)`, com só o pedaço que mudou):** o primeiro traço, de qualquer ferramenta e mesmo numa área pequena, levava o editor de 17 a ~220 MB de memória gráfica (285 MB com o pixelado). Com camadas, 22 MB.

Ainda não validado no uso: o cursor de mira e de redimensionar com a janela sem ativar o processo; digitar com acento de verdade (no teste o texto entra direto na caixa); o `Option S` pelo tap. Limitações: uma tela por vez (a do mouse); o clipboard recebe só PNG; não dá pra mexer num desenho depois de feito (só desfazer).

## Distribuição: NiriOS.app, Homebrew e update (2026-10-16)

`./scripts/app.sh 0.1.0` monta o `NiriOS.app` em `.build/dist`, assina e gera o zip. `./scripts/release.sh 0.1.0 "notas"` faz isso, marca o código com a tag `v0.1.0`, cria a release em [deandevz/niri-os-releases](https://github.com/deandevz/niri-os-releases) (repo público só com os apps: nasceu quando este era privado, e o update das versões já instaladas lê de lá) e atualiza o cask `niri-os` no `homebrew-tap`. As notas aparecem na janela do update.

- **O app:** bundle id `com.kingdeanprod.niri-os`, só Apple Silicon, `LSMinimumSystemVersion` 15.0 (as APIs privadas só foram medidas no 26; liberado pro 15 em 2026-10-16 pra testar num Sequoia), `LSUIElement` (sem Dock). Compilado em `.build/app`, porque em `.build/release` pode estar o niri-os de uso rodando. O ícone sai de `scripts/icon.swift`.
- **Assinatura:** certificado autoassinado "NiriOS" (SHA-1 `2200F6F6BFFD090A9B35104FFA61475BD4A70903`, vale até 2046), no chaveiro de login. A regra que o macOS guarda junto com a Acessibilidade e a Gravação de Tela é `identifier "com.kingdeanprod.niri-os" and certificate root = H"2200f6…"`, igual em toda versão. Com assinatura ad-hoc (sem certificado) a regra seria o hash do binário: cada versão perderia as permissões, e a chave continuaria ligada nos Ajustes sem funcionar. O certificado e a chave privada ficam fora do repositório. Sem ele, a versão seguinte não passa no update e todo mundo reinstala e libera as permissões de novo: guardar cópia fora do Mac. Runtime endurecido (`--options runtime`): o app ignora `DYLD_INSERT_LIBRARIES`, senão qualquer processo do usuário abriria o NiriOS com código seu e herdaria a Acessibilidade dele.
- **Homebrew:** cask `niri-os` no tap `deandevz/tap`, copiado do King Bot. `auto_updates true` (o app se atualiza e o brew só instala), quarentena tirada com `xattr` depois de instalar (sem Developer ID nem notarização, o Gatekeeper bloquearia), `uninstall quit` (sair pelo macOS devolve as janelas pra tela).
- **Update (`Updater`):** o niri-os abre `niri-os --update` 1 min depois de abrir e depois a cada 24 h, no relógio de parede (no monotônico, o tempo com o Mac dormindo não conta), e pelo "Procurar atualização" da aba Geral. O processo lê `releases/latest` do repo público, baixa o zip numa pasta da mesma partição do app e confere o bundle id, a versão da tag e a assinatura com a regra deste app (`SecStaticCodeCheckValidity`). Só então pergunta, com as notas. "Atualizar agora" passa o caminho pro niri-os, que troca o app num rename (`replaceItemAt`; se falhar, continua na versão de antes), guarda o estado sem mexer nas janelas (como o `SIGUSR1`) e reabre. "Depois" apaga o baixado, e amanhã pergunta de novo. Num processo à parte, como o painel: URLSession e SwiftUI deixariam memória presa no niri-os.
- **Reabrir no app é pelo LaunchServices** (`AppBundle.relaunch`, também na fita ligada ou desligada e no fim do tour): filho do processo velho, as permissões seriam conferidas no processo que abriu, que vai sair. O processo novo recebe os argumentos e só as variáveis `NIRI_*` (as de teste).
- **Um gerenciador por vez:** lock em `Application Support/niri-os/niri-os.lock`, solto quando o processo sai (até caindo). O macOS não abre o app duas vezes, mas o `.build/release/niri-os` e o NiriOS.app abririam. Espera até 3 s, porque no reinício o processo velho ainda está saindo. Teste (`--pid`, `--script`) não pega o lock.
- **Sair pelo macOS** (logout, desligar, `brew uninstall`, Encerrar no Monitor de Atividade) é o mesmo do `Ctrl+C`. Antes o processo saía com as janelas estacionadas na borda.
- **Log:** no app vai pra `~/Library/Logs/niri-os.log` (aberto pelo Finder ou no login, o stderr iria pro nada), e passando de 5 MB o de antes vira `niri-os.old.log`. "Mostrar o log" na aba Geral. Rodando do terminal, continua no terminal.
- **Abrir ao iniciar:** `SMAppService.mainApp`, na aba Geral e no fim do tour (ligado por padrão). O estado fica no macOS (Ajustes > Geral > Itens de início), não no config.

Medido (2026-10-16, servidor local fingindo o GitHub, zip de 950 KB):

- Baixar, abrir e conferir a versão nova: ~20 ms. O app baixado não tem quarentena (o niri-os não marca o que baixa).
- Versão assinada por outro certificado (o "King Bot Dev"): recusada com `-67050` (a regra não bate), e o baixado sai do disco. Na conferência diária, erro não abre janela, só vai pro log.
- O processo do update: 21 MB com a janela aberta, e sai ao fechar. O niri-os de uso com o código novo: 12 MB e 0% de CPU parado, como antes.
- Segundo niri-os sem `--pid` com o de uso aberto: recusa em 3,4 s ("O NiriOS já está aberto").

De ponta a ponta, com o app de teste em `~/Applications` e `--pid` (2026-10-16): o tour terminou e reabriu como gerenciador em 75 ms, com o config de tudo desligado. A conferência do update rodou 60 s depois de abrir, e da troca até a 0.0.2 aberta foram 0,45 s, sem o tour: a Acessibilidade continuou valendo. Na 0.0.2, um resize no teste moveu as janelas ("tudo no lugar") e o vidro mediu o redesenho ("pronta em 102 ms" e "em 84 ms"), então a Gravação de Tela também continuou valendo. Maior intervalo entre frames de 10,0 ms, com o runtime endurecido. Ligar a fita reabriu pelo LaunchServices em 62 ms. Abrir ao iniciar: o tour registrou (`enabled, allowed`), a aba Geral leu o estado depois do update e desligou. Sair pelo macOS (`NSRunningApplication.terminate`) foi pelo caminho do `Ctrl+C`, e o painel aberto saiu junto.

- **A lista da Acessibilidade só mostra app registrado no LaunchServices.** O app de teste em `/private/tmp` pediu a permissão, e o `tccd` criou o registro, mas a lista dos Ajustes não mostrava o NiriOS: `failed to find an Application URL for bundle ID`. O macOS não registra app em pasta temporária. Em `~/Applications` (e em /Applications, onde o brew instala) apareceu na hora.
- **"Sair e reabrir" da Gravação de Tela reabre o app sem argumentos.** No teste, ele leu o config de uso e o lock do niri-os de uso fez ele se recusar a abrir, em vez de brigar pelas janelas. No uso de verdade não tem outro niri-os, e sem config ele volta pro tour.

### Primeira abertura (`Welcome`)

O NiriOS.app sem `config.json` abre o tour: boas-vindas, permissões, o que ligar (fita, borda e histórico, tudo desligado), os atalhos e "abrir ao iniciar". No fim grava o config com o que ficou desligado e reabre como o gerenciador. Fechar a janela com a Acessibilidade liberada é terminar com o que foi escolhido até ali; sem ela, o app sai, e a próxima abertura volta pra mesma tela (`welcomePage` nos defaults). Sem a Acessibilidade e com config (tirada nos Ajustes, ou um app de outro certificado), só a página das permissões.

- **Roda antes da fita, no próprio processo, e reabre no fim:** os ~40 MB do SwiftUI que não voltam (seção "Barra de menu") saem com o processo.
- **No Dock enquanto está aberto** (`.regular`): a pessoa vai nos Ajustes do Sistema liberar e precisa achar a volta. Liberou a Acessibilidade, a janela volta pra frente sozinha.
- **As permissões não avisam quando mudam:** conferidas a cada 0,5 s, só com o tour aberto.
- **Gravação de Tela:** o macOS pede pra reabrir o app depois de liberar ("Sair e reabrir"). Reaberto sem config, o tour volta na tela das permissões. Ela é recomendada, não obrigatória: sem ela o vidro do resize espera 300 ms fixos e a borda não mede o canto das janelas quadradas.
- **Outro gerenciador aberto** (AeroSpace, OmniWM): o tour avisa ao ligar a fita, e o niri-os só se recusa a abrir com a fita ligada.

## Testar sem mexer nas suas janelas

```sh
swift build -c release
./painel-de-teste &   # qualquer app com janelas; painéis flutuantes servem
.build/release/niri-os -v --pid <pid> --script right,right,grow,full,full,shrink,left,move:2,ws:2,ws:1
```

`--pid` faz o niri-os cuidar só daquele app, numa faixa no pé da tela, sem atalhos e sem roubar foco. Com `NIRI_CONFIG` e sem `--script`, o teste também ganha o ícone e a recarga do config (pra testar ligar e desligar recursos, inclusive a fita, sem mexer no config de uso). Com o niri-os de uso aberto, rode o de teste de uma cópia do executável (`cp .build/release/niri-os /tmp/niri-os-teste`): com dois processos do mesmo arquivo, a captura de janela do segundo (`SLSHWCaptureWindowList`, que passa pelo `replayd`) nunca volta (visto em 2026-10-16). O vidro do resize sai mesmo assim depois de 0,85 s, e as capturas param até reiniciar. Sem `--pid`, o `--script` roda nas janelas de verdade e troca o foco; no fim sai sem mexer nas janelas (como o `SIGUSR1`). O script começa da janela focada, então confira qual app está na frente antes. Funciona com o OmniWM aberto. No fim ele lê o frame real de cada janela e compara com o esperado (sai com código 2 se algo ficou fora do lugar). `./scripts/test.sh` roda os testes do layout. Um deles confere em todo frame de 6 animações que o espaço entre janelas é exatamente o `gap`.

`niri-os --list` lista as janelas e se entrariam na fita (ou por que não), sem mexer em nada. `NIRI_UPDATE_URL=<url>` troca a release que o update lê (um JSON no formato do `releases/latest` do GitHub, servido de um servidor local). O tour aparece no NiriOS.app com `NIRI_CONFIG` apontando pra um arquivo que não existe (`open -n NiriOS.app --env NIRI_CONFIG=... --args --pid <pid>`). `NIRI_CONFIG=<arquivo>` usa outro config (pra testar uma config sem mexer na de uso). `NIRI_CLIPBOARD=<pasta>` liga o histórico do clipboard no teste, com outra pasta: `clipboard` no `--script` abre e fecha o painel, e `wait` é um passo sem ação (qualquer outro atalho fecha o painel). No `--script`, `move-left` e `move-right` trocam a coluna focada de lugar, `stack-left` e `stack-right` empilham ou separam, `taller`, `shorter`, `up` e `down` são a altura e o foco na coluna, `ws:<nome>` vai pro workspace e `move:<nome>` manda a focada pra ele; em teste o `open` e o `onWorkspaceChange` não rodam. `screenshot` abre o editor do print (com `-v`, os tempos da tecla à foto e à janela). `NIRI_SCREENSHOT_SCRIPT` faz o editor seguir um roteiro em vez do mouse e do teclado de verdade, com eventos na fila da própria janela: `wait 0.4; drag 300 250 1000 750; key a; drag 340 300 600 450; key t; click 650 620; type Olá; key esc; key cmd+s` (pontos da tela com y pra baixo; `shift` no fim do `drag` segura o Shift). Evento mandado com `CGEventPostToPid` não serve: o clique chega com a posição trocada e os seguintes se perdem. O editor aparece na tela, e `key cmd+c` escreve no clipboard de uso.

## Limitações conhecidas

- Transição do resize: o efeito translúcido de barra lateral (vibrancy, ex.: WhatsApp) não vem na foto e fica um tom diferente durante a animação; conteúdo das janelas vizinhas fica parado por ~0,4 s (vídeo congela); a rolagem (`< >`) ainda anima as janelas reais (e o WhatsApp atrasa ~1 frame em relação às vizinhas).

- **Apps diferentes podem se sobrepor por um frame** durante a animação. Cada app aplica na sua fila, sem ordem entre filas. A ordem dentro do mesmo app já evita isso. Próximo experimento: congelar a atualização da tela durante o lote do frame (`SLSDisableUpdate`) ou transações do SkyLight, sem SIP.
- Janela com largura mínima maior que a coluna: o app recusa e a janela invade a vizinha.
- Coluna empilhada: janela nova sempre abre numa coluna nova (como no niri); não dá pra arrastar com o mouse pra dentro de uma pilha.
- Diálogos, sheets e painéis ficam fora da fita (flutuam). Centralizar sobre a janela dona ainda não foi feito.
- Papel de parede: efeito só em imagem (no vídeo seria um filtro por quadro); render pro tamanho da tela principal, aplicado em todas.
- Só a tela principal. Com outra tela ao lado, as janelas estacionadas (inclusive as dos outros workspaces) apareceriam nela. Esconder um app (Cmd+H), minimizar ou pôr em tela cheia tira a janela da fita; ao voltar, ela vai pro mesmo workspace, entre as mesmas vizinhas.
- Sem janela flutuante ainda: o que o AeroSpace deixava flutuando (Finder, Ajustes, Adobe) entra na fita.
- Se o processo morrer sem Ctrl+C, as janelas ficam estacionadas na borda. Rodar de novo (e sair com Ctrl+C) devolve.
