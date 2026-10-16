# NiriOS

Tiling em fita horizontal pro macOS, no modelo do niri. Protótipo do MVP: workspaces, tela principal.

## Rodar

1. Feche o OmniWM (o niri-os se recusa a abrir com ele rodando: os dois brigariam pelas janelas).
2. O terminal que roda o niri-os precisa de permissão em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade.
3. `./scripts/run.sh` (ou `./scripts/run.sh -v` pra ver as medições de cada animação).
4. Clique (esquerdo ou direito) no ícone da barra de menu (três colunas) abre o painel de configurações.
5. `Ctrl+C`, ou "Sair do NiriOS" no painel, devolve todas as janelas pra dentro da tela e sai.

| Atalho | Ação |
|---|---|
| `Option +` / `Option -` | largura da coluna focada: pula entre 1/3, 1/2, 2/3 e tela cheia (como no niri) |
| `Option ,` / `Option .` (ou `<` `>`, ou `←` `→`) | foco pra coluna da esquerda / direita, a fita rola junto |
| `Option F` | coluna em largura total; de novo volta à largura anterior |
| `Option D` | mostra a mesa: as janelas saem pela borda mais próxima, sem os ícones da mesa; de novo voltam |
| `Option 1` a `Option 4` (e a letra de cada workspace) | vai pro workspace; a fita atual sai de lado e a dele entra |
| `Option Shift 1` a `4` (idem) | manda a janela focada pra esse workspace |

Segurar a tecla repete (só o resize e o foco). Janela nova entra à direita da focada com 50% da largura; nenhuma outra encolhe. Esses são os atalhos padrão; todos podem ser trocados (abaixo).

Config opcional em `~/.config/niri-os/config.json` (todas as chaves opcionais). O painel grava nele, e salvar o arquivo à mão também aplica na hora:

```json
{ "gap": 12, "topPadding": 0, "bottomPadding": 0, "defaultColumnWidth": 0.5,
  "widthPresets": [0.333, 0.5, 0.667, 1], "resizeStyle": "ghost", "stiffness": 800,
  "shortcuts": { "grow": ["option+=", "ctrl+option+up"], "toggleFullWidth": [] },
  "ghostBorderColor": "#BE00F9", "ghostBorderWidth": 3,
  "wallpaper": "~/Pictures/fundo.jpg", "wallpaperEffect": "dither",
  "workspaces": ["1", "2", { "name": "T", "apps": ["com.github.wez.wezterm"], "open": "WezTerm" }],
  "onWorkspaceChange": "sketchybar --trigger niri_workspace_change FOCUSED_WORKSPACE=$NIRI_WORKSPACE" }
```

`shortcuts`: ações `grow`, `shrink`, `focusLeft`, `focusRight`, `toggleFullWidth`, `toggleDesktop`. Uma ação no arquivo troca a lista inteira dela (as outras ficam no padrão); `[]` desliga. Atalho = modificadores (`ctrl`, `option`, `shift`, `cmd`) + tecla: letra, número, símbolo (`` = - , . / ; ' [ ] \ ` ``), `left` `right` `up` `down`, `space`, `return`, `tab`, `escape`, `delete`, `home` `end` `pageup` `pagedown`, `f1` a `f12`, `keypadplus` `keypadminus`, ou `key<código>`. A tecla vale pela posição (igual em US e ABNT2). Com Shift apertado e sem atalho próprio com Shift, vale o mesmo sem ele (`Option <` = `Option ,`). O mesmo atalho em duas ações: vale a primeira, com aviso. `ghostBorderColor`: `#RRGGBB`, `#RRGGBBAA` ou `accent` (cor de destaque do sistema, o padrão); `ghostBorderWidth` em pt (0 tira a borda). `wallpaper`: imagem ou vídeo (`.mp4`, `.mov`, `.m4v`); sem a chave, o niri-os não mexe no papel de parede do macOS (e devolve o de antes, se o atual era dele). `wallpaperEffect`: `none` (padrão), `dither`, `halftone`, `scanlines` ou `ascii`, só pra imagem. Detalhes em "Mesa e papel de parede". `workspaces` e `onWorkspaceChange`: seção "Workspaces".

Ao recarregar: atalhos, borda, papel de parede e regras de app valem na hora; a lista de workspaces também (as janelas de um que saiu da lista vão pro atual); `gap`, margens, `defaultColumnWidth`, `stiffness` e `centerFocusedColumn` animam as janelas pro lugar novo (nada pula); `widthPresets` e `widthStep` valem na próxima tecla; `resizeStyle` e `axTimeout` só ao reiniciar. Arquivo com JSON inválido: usa os padrões, avisa no log e no painel, e o painel não grava por cima (perderia o que foi escrito à mão).

`topPadding` serve pra SketchyBar. `stiffness` maior = animação mais rápida (800 ≈ 0,35 s, igual ao niri). `widthPresets: []` volta pro passo fixo de `widthStep` (padrão 0.1). `resizeStyle` é como o `Option +/-` anima: `ghost` (padrão, vidro fosco no lugar da janela, abaixo), `photos` (fotos das janelas, abaixo; precisa da permissão de Gravação de Tela pro terminal, e sem ela vira `live`) ou `live` (as janelas reais, frame a frame).

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

Ideia da prévia do Loop (MrKai77/Loop): em vez de fotografar, um vidro fosco nosso (`NSVisualEffectView` `.hudWindow`, borda na cor de destaque, canto de 16 pt) anda no lugar da janela que muda de tamanho.

1. Na tecla, o vidro entra no lugar da janela e ela vai pra fora da tela (1 pt na borda direita). Encolhendo, o tamanho novo é aplicado antes de sair, ainda na tela e por baixo do vidro, porque fora da tela o Electron recusa resize.
2. A fita anima: as vizinhas são as janelas reais (só posição, como no `< >`), e o vidro segue o frame da janela escondida. Outra tecla no meio só muda o alvo da fita.
3. Fita parada e Option solto (ou seguro, sem nenhuma tecla, por 0,5 s): a janela volta no lugar e tamanho finais, por baixo do vidro. Só com a fita parada, apertando `+/-` várias vezes ela parava entre uma tecla e outra e a página aparecia pelo vidro até a tecla seguinte, que veio 320 a 370 ms depois de a fita parar. Só com o Option, quem segura ele depois da tecla esperava ~2,8 s. O vidro só começa a sumir 150 ms depois que o app terminou de redesenhar: captura da janela (não aparece na tela) até ela ter a largura final e ficar 50 ms sem mudar, no máximo 600 ms (vídeo tocando nunca para). Os 150 ms são porque alguns apps ainda se reorganizam depois dos 50 ms parados, e isso aparecia no fade. Aí some em 350 ms, com curva suave no começo e no fim. Sem Gravação de Tela, espera fixa de 300 ms.
4. A conferência pós-animação espera o vidro sumir, senão leria o tamanho velho e mandaria o resize de novo no meio do redesenho.

Primeira versão saía com tempo fixo (100 ms de espera + fade de 200 ms): o usuário achou a saída brusca, dava pra ver a página do Arc se reorganizando e o texto do WezTerm refluindo durante o fade. Com a espera pela captura, num painel de teste que pisca por 300 ms depois de cada resize, o vidro esperou 369 e 380 ms.

Ícone do app no meio do vidro (96 pt, `NSRunningApplication.icon` num `NSImageView` com margens elásticas: o AppKit recentraliza quando o vidro muda de tamanho, sem código por frame). Sai junto com o vidro no fade. A/B nos painéis de teste, 8 resizes, 2 rodadas cada: pico de 15 MB contra 14 MB sem ícone, CPU e maior intervalo entre frames iguais (~16 ms).

Primeira medição (2026-10-15, painéis de teste, 5 resizes seguidos): maior intervalo entre frames de 8,4 a 16,9 ms, CPU ~2,5% durante a animação (as fotos: 27 a 40%), memória 10 MB com pico de 10 MB (as fotos: 13 MB parado e ~28 MB de pico). Começa a mexer na hora da tecla, sem esperar o app. Avaliação do usuário nos apps reais: "melhorou demais, esse é o caminho"; virou o padrão no lugar das fotos.

## Barra de menu e painel de configurações (2026-10-15)

Ícone na barra (três colunas, a do meio maior: a fita com a focada no centro). Clique esquerdo ou direito abre o painel, com uma aba por assunto na barra de ferramentas, como os Ajustes dos apps do Mac (desde 2026-10-16; antes era uma página só, com texto explicando cada parte). A janela muda de altura com a aba e abre na última usada.

- **Atalhos:** gravar um novo com `+` (Esc cancela; sem ⌃ ⌥ ⌘ a tecla avisa "Use ⌃, ⌥ ou ⌘"), remover com o x no canto da tecla, voltar ao padrão.
- **Workspaces:** a lista na ordem da tela, com os ícones dos apps de cada um. `+` cria (o próximo número livre), `−` apaga (as janelas dele vão pro workspace da tela), arrastar muda a ordem. À direita, o escolhido: nome, os dois atalhos, os apps que abrem nele e o app que abre quando ele está vazio (`open`).
- **Papel de parede:** prévia, arquivo e efeito.
- **Borda:** cor e espessura do vidro do resize, com prévia (o mesmo `NSVisualEffectView` do resize, sobre o papel de parede).
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

**Largura mínima só com duas leituras (2026-10-16).** Uma leitura só, 150 ms depois de assentar, pegava app assíncrono ainda no tamanho velho, e o limite errado ficava salvo e mudava o tamanho sozinho (Arc 1704, WhatsApp 1643, Discord 1223 pt, depois das janelas entrarem como novas). Agora vale só se a 2ª leitura, 0,6 s depois, confirma, e nunca a largura toda da área.

**Workspace vazio não volta sozinho (2026-10-16).** Duas vezes, 1,5 s depois de ir pro 4 vazio, o app que ficou com o teclado (King Bot, WhatsApp) avisou foco de novo e a tela voltou pro workspace dele. Agora aviso da janela que ficou com o teclado ao ir pra um workspace vazio não troca de workspace; pra voltar, o atalho.

**Conferência pelo WindowServer (com -v).** Depois de cada animação, sem falar com os apps, o niri-os compara onde cada janela está com onde deveria estar e registra no log (`conferência: ...`) janela fora do lugar ou janela de app observado na tela fora da fita (a que está no vidro do resize não conta). É o jeito de pegar janela vazando de outro workspace e app que não entra na fita (Steam).

**Janela de outro workspace vazando (2026-10-16).** O WhatsApp atrás do WezTerm, a aba anônima do Arc por cima de outro workspace e as sobreposições com 6 painéis eram o mesmo bug: o workspace que sai da tela era deslocado em exatamente uma largura de tela, e isso só tira da tela o que estava inteiro nela. No 2 (Discord e WhatsApp, os dois com largura total), o WhatsApp fica logo à direita da tela; com o 2 deslocado uma tela pra esquerda, ele caía em x = 0, dentro da tela, atrás da janela focada, e a conferência pós-animação ainda "corrigia" ele pra lá. A correção: durante a troca, só desliza a coluna que está inteira na tela do workspace; a que está fora da viewport, ou só em parte na tela (uma de 2/3 com uma de 1/2 do lado), fica escondida durante a troca e volta no fim. Testes `offscreenColumnsOfWideStripStayParkedWhileSwitching`, conferidos falhando sem a correção. Nos painéis (6 painéis, 22 ações, 2 rodadas): 0 frames com sobreposição, antes 3 a 54.

**Coluna em parte na tela desliza junto (2026-10-16).** A correção acima escondia na troca a coluna só em parte na tela, e ela voltava de uma vez no fim: no 2, com o Discord de 2/3 focado, o pedaço do WhatsApp na borda direita sumia ao sair e "nascia" depois que o Discord chegava. Agora toda coluna que aparece na tela, mesmo só em parte, desliza com a fita, e a troca anda o bastante pra tirar ela inteira: uma tela, ou mais quando uma coluna passa da borda, sem a fita nova encostar na velha (as duas ficam a um gap uma da outra). No 2 do uso são 2860 pt em vez de 1728, no mesmo tempo de mola; o resto do WhatsApp, que estava fora da tela, aparece passando. A coluna fora da viewport continua estacionada, e fita parada fora da tela fica toda estacionada, mesmo que tenha mudado depois de sair (janela nova, largura aprendida). Testes `partlyVisibleColumnOnTheRightSlidesWithItsStrip` e `...OnTheLeft...` (os dois lados da borda, nos dois sentidos, com gap exato entre a coluna e a vizinha em todo frame); no código anterior a coluna aparecia em 0 ou 1 frame da troca.

Tela cheia nativa (2026-10-16): entrar e sair de tela cheia troca de Space sem nenhum aviso de janela que a gente escute, então a janela que saía da tela cheia ficava solta por cima ou por trás da fita até ser minimizada (o "minimizar conserta" que o usuário viu). Agora a troca de Space relê todos os apps, na hora e 0,5 s depois. Ao entrar em tela cheia, a janela sai da fita sem o foco ir pra vizinha (isso tirava a pessoa do Space da tela cheia), e a conferência pós-animação para de mexer nela (antes mandava o tamanho e a posição da fita pra janela em tela cheia). Ao sair, ela volta pro mesmo workspace, entre as mesmas vizinhas; o mesmo vale pra minimizada e app escondido.

Ainda não conferido no uso real: as regras de foco acima com os apps de verdade (no `--pid` o niri-os não troca o foco), a tela cheia (testar mexeria no Space de quem está usando o Mac), e o clique na mesa com o Finder tendo janela em outro workspace.

## Testar sem mexer nas suas janelas

```sh
swift build -c release
./painel-de-teste &   # qualquer app com janelas; painéis flutuantes servem
.build/release/niri-os -v --pid <pid> --script right,right,grow,full,full,shrink,left,move:2,ws:2,ws:1
```

`--pid` faz o niri-os cuidar só daquele app, numa faixa no pé da tela, sem atalhos e sem roubar foco. Sem `--pid`, o `--script` roda nas janelas de verdade e troca o foco; no fim sai sem mexer nas janelas (como o `SIGUSR1`). O script começa da janela focada, então confira qual app está na frente antes. Funciona com o OmniWM aberto. No fim ele lê o frame real de cada janela e compara com o esperado (sai com código 2 se algo ficou fora do lugar). `./scripts/test.sh` roda os testes do layout. Um deles confere em todo frame de 6 animações que o espaço entre janelas é exatamente o `gap`.

`niri-os --list` lista as janelas e se entrariam na fita (ou por que não), sem mexer em nada. `NIRI_CONFIG=<arquivo>` usa outro config (pra testar uma config sem mexer na de uso). No `--script`, `ws:<nome>` vai pro workspace e `move:<nome>` manda a focada pra ele; em teste o `open` e o `onWorkspaceChange` não rodam.

## Limitações conhecidas

- Transição do resize: o efeito translúcido de barra lateral (vibrancy, ex.: WhatsApp) não vem na foto e fica um tom diferente durante a animação; conteúdo das janelas vizinhas fica parado por ~0,4 s (vídeo congela); a rolagem (`< >`) ainda anima as janelas reais (e o WhatsApp atrasa ~1 frame em relação às vizinhas).

- **Apps diferentes podem se sobrepor por um frame** durante a animação. Cada app aplica na sua fila, sem ordem entre filas. A ordem dentro do mesmo app já evita isso. Próximo experimento: congelar a atualização da tela durante o lote do frame (`SLSDisableUpdate`) ou transações do SkyLight, sem SIP.
- Janela com largura mínima maior que a coluna: o app recusa e a janela invade a vizinha.
- Diálogos, sheets e painéis ficam fora da fita (flutuam). Centralizar sobre a janela dona ainda não foi feito.
- Papel de parede: efeito só em imagem (no vídeo seria um filtro por quadro); render pro tamanho da tela principal, aplicado em todas.
- Só a tela principal. Com outra tela ao lado, as janelas estacionadas (inclusive as dos outros workspaces) apareceriam nela. Esconder um app (Cmd+H), minimizar ou pôr em tela cheia tira a janela da fita; ao voltar, ela vai pro mesmo workspace, entre as mesmas vizinhas.
- Sem janela flutuante ainda: o que o AeroSpace deixava flutuando (Finder, Ajustes, Adobe) entra na fita.
- Se o processo morrer sem Ctrl+C, as janelas ficam estacionadas na borda. Rodar de novo (e sair com Ctrl+C) devolve.
