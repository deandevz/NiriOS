# NiriOS

Tiling em fita horizontal pro macOS, no modelo do niri. Protótipo do MVP: um workspace, tela principal.

## Rodar

1. Feche o OmniWM (o niri-os se recusa a abrir com ele rodando: os dois brigariam pelas janelas).
2. O terminal que roda o niri-os precisa de permissão em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade.
3. `./scripts/run.sh` (ou `./scripts/run.sh -v` pra ver as medições de cada animação).
4. `Ctrl+C` devolve todas as janelas pra dentro da tela e sai.

| Atalho | Ação |
|---|---|
| `Option +` / `Option -` | largura da coluna focada: pula entre 1/3, 1/2, 2/3 e tela cheia (como no niri) |
| `Option ,` / `Option .` (ou `<` `>`, ou `←` `→`) | foco pra coluna da esquerda / direita, a fita rola junto |
| `Option F` | coluna em largura total; de novo volta à largura anterior |

Segurar a tecla repete (menos o `Option F`). Janela nova entra à direita da focada com 50% da largura; nenhuma outra encolhe.

Config opcional em `~/.config/niri-os/config.json` (todas as chaves opcionais):

```json
{ "gap": 12, "topPadding": 0, "bottomPadding": 0, "defaultColumnWidth": 0.5,
  "widthPresets": [0.333, 0.5, 0.667, 1], "photoTransitions": true, "stiffness": 800 }
```

`topPadding` serve pra SketchyBar. `stiffness` maior = animação mais rápida (800 ≈ 0,35 s, igual ao niri). `widthPresets: []` volta pro passo fixo de `widthStep` (padrão 0.1). `photoTransitions` é a transição do resize por fotos (abaixo); precisa da permissão de Gravação de Tela pro terminal, e sem ela o resize anima as janelas reais direto.

## Como funciona

- **Layout** (`Sources/NiriCore`): fita de colunas + viewport, sem AppKit. A largura e a rolagem são molas criticamente amortecidas (modelo do niri). Trocar o alvo no meio preserva a velocidade, então segurar a tecla não dá tranco.
- **Uma fila por app** (`AppWorker`): toda chamada de Acessibilidade pra um app passa pela fila dele. A animação roda a 120 Hz (display link). Se o app ainda está ocupado com o frame anterior, os intermediários são descartados e ele pula pro mais recente. App lento só atrasa as próprias janelas.
- **Janela fora da tela**: o macOS puxa de volta pra 40 pt visíveis qualquer janela 100% fora da tela, mas aceita 1 pt. Então janela fora da viewport fica "estacionada" na borda com 1 pt visível, dentro da margem. O OmniWM faz o mesmo (as janelas dele ficam em x=1727).
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
- **Spam de `< >` só rola; o app onde parar é ativado quando a fita assenta** (padrão desde 2026-10-15). A 1ª tecla com a fita parada ativa na hora. Antes, cada app atravessado era ativado e desativado, redesenhava e parava de responder AX: num spam de 6 s, maior intervalo Arc 403 ms, outro app 326, WhatsApp 208, Zed 73 (a main em 8,7). Depois, em 10 spams de 1 a 5 s: todos ≤ ~21 ms, menos o WezTerm (até 37). Custo: depois de um spam, o teclado só muda de janela ~0,4 s depois da última tecla.
- **Gravando com o OBS (janela dele na fita), ainda trava:** OBS, Spotify e WezTerm batem no timeout de 200 ms; Arc e outro navegador Chromium ~53 ms. O OBS responde AX a 7,6 ms/frame em média (até 35). Falta separar a janela do OBS na fita da carga da gravação.
- **Experimento, desligado: `NIRI_FOCUS_DELAY=45`** (ms). Ao perder foco o WhatsApp fica ~25 a 45 ms sem responder (redesenho de ativo pra inativo). Começando a rolagem 45 ms depois da tecla, ele passou a andar junto com as outras (atraso de 4 a 14 ms em vez de até 72). Não resolve o desencontro de ~1 frame entre apps na rolagem (90 e 130 ms também não).

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

### Transição do resize por fotos (`TransitionOverlay`, padrão)

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

## Testar sem mexer nas suas janelas

```sh
swift build -c release
./painel-de-teste &   # qualquer app com janelas; painéis flutuantes servem
.build/release/niri-os -v --pid <pid> --script right,right,grow,full,full,shrink,left
```

`--pid` faz o niri-os cuidar só daquele app, numa faixa no pé da tela, sem atalhos e sem roubar foco. Sem `--pid`, o `--script` roda nas janelas de verdade e troca o foco; no fim sai sem mexer nas janelas (como o `SIGUSR1`). O script começa da janela focada, então confira qual app está na frente antes. Funciona com o OmniWM aberto. No fim ele lê o frame real de cada janela e compara com o esperado (sai com código 2 se algo ficou fora do lugar). `./scripts/test.sh` roda os testes do layout. Um deles confere em todo frame de 6 animações que o espaço entre janelas é exatamente o `gap`.

`niri-os --list` lista as janelas e se entrariam na fita (ou por que não), sem mexer em nada.

## Limitações conhecidas

- Transição do resize: o efeito translúcido de barra lateral (vibrancy, ex.: WhatsApp) não vem na foto e fica um tom diferente durante a animação; conteúdo das janelas vizinhas fica parado por ~0,4 s (vídeo congela); a rolagem (`< >`) ainda anima as janelas reais (e o WhatsApp atrasa ~1 frame em relação às vizinhas).

- **Apps diferentes podem se sobrepor por um frame** durante a animação. Cada app aplica na sua fila, sem ordem entre filas. A ordem dentro do mesmo app já evita isso. Próximo experimento: congelar a atualização da tela durante o lote do frame (`SLSDisableUpdate`) ou transações do SkyLight, sem SIP.
- Janela com largura mínima maior que a coluna: o app recusa e a janela invade a vizinha.
- Diálogos, sheets e painéis ficam fora da fita (flutuam). Centralizar sobre a janela dona ainda não foi feito.
- Só a tela principal e um workspace. Esconder um app (Cmd+H) tira as janelas dele da fita; ao reaparecer, elas voltam à direita da focada.
- Se o processo morrer sem Ctrl+C, as janelas ficam estacionadas na borda. Rodar de novo (e sair com Ctrl+C) devolve.
