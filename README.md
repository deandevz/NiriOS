# NiriOS

Tiling em fita horizontal pro macOS, no modelo do niri. Protótipo do MVP: um workspace, tela principal.

## Rodar

1. Feche o OmniWM (o niri-os se recusa a abrir com ele rodando: os dois brigariam pelas janelas).
2. O terminal que roda o niri-os precisa de permissão em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade.
3. `./scripts/run.sh` (ou `./scripts/run.sh -v` pra ver as medições de cada animação).
4. `Ctrl+C` devolve todas as janelas pra dentro da tela e sai.

| Atalho | Ação |
|---|---|
| `Option +` / `Option -` | largura da coluna focada (±10% da tela) |
| `Option ,` / `Option .` (ou `<` `>`, ou `←` `→`) | foco pra coluna da esquerda / direita, a fita rola junto |
| `Option F` | coluna em largura total; de novo volta à largura anterior |

Segurar a tecla repete (menos o `Option F`). Janela nova entra à direita da focada com 50% da largura; nenhuma outra encolhe.

Config opcional em `~/.config/niri-os/config.json` (todas as chaves opcionais):

```json
{ "gap": 12, "topPadding": 0, "bottomPadding": 0, "defaultColumnWidth": 0.5, "widthStep": 0.1, "stiffness": 800 }
```

`topPadding` serve pra SketchyBar. `stiffness` maior = animação mais rápida (800 ≈ 0,35 s, igual ao niri).

## Como funciona

- **Layout** (`Sources/NiriCore`): fita de colunas + viewport, sem AppKit. A largura e a rolagem são molas criticamente amortecidas (modelo do niri). Trocar o alvo no meio preserva a velocidade, então segurar a tecla não dá tranco.
- **Uma fila por app** (`AppWorker`): toda chamada de Acessibilidade pra um app passa pela fila dele. A animação roda a 120 Hz (display link). Se o app ainda está ocupado com o frame anterior, os intermediários são descartados e ele pula pro mais recente. App lento só atrasa as próprias janelas.
- **Janela fora da tela**: o macOS puxa de volta pra 40 pt visíveis qualquer janela 100% fora da tela, mas aceita 1 pt. Então janela fora da viewport fica "estacionada" na borda com 1 pt visível, dentro da margem. O OmniWM faz o mesmo (as janelas dele ficam em x=1727).
- **Foco**: `_SLPSSetFrontProcessWithOptions` + evento de "make key" via `SLPSPostEventRecordTo` (SkyLight, funciona com SIP ligado, mesma técnica do yabai/AltTab) + `AXRaise`. Pedidos de foco passam por uma fila única e só o último vale. Eco de pedidos antigos é ignorado por 0,5 s, senão o layout "voltaria sozinho".
- **Atalhos**: CGEventTap numa thread própria (engole a tecla, então o app não recebe "≠" nem "ƒ").
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

Ainda sobra: o resize do WhatsApp continua em ~7 tamanhos por segundo, e ao perder foco ele fica ~30 ms sem responder (é o redesenho dele de ativo pra inativo). Brigar com o ritmo de cada app não resolve. Próximo experimento: durante a animação, animar fotos das janelas (nossas, a 120 Hz) e mandar pro app só o frame final, trocando a foto pelo app real no fim.

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

- **Apps diferentes podem se sobrepor por um frame** durante a animação. Cada app aplica na sua fila, sem ordem entre filas. A ordem dentro do mesmo app já evita isso. Próximo experimento: congelar a atualização da tela durante o lote do frame (`SLSDisableUpdate`) ou transações do SkyLight, sem SIP.
- Janela com largura mínima maior que a coluna: o app recusa e a janela invade a vizinha.
- Diálogos, sheets e painéis ficam fora da fita (flutuam). Centralizar sobre a janela dona ainda não foi feito.
- Só a tela principal e um workspace. Esconder um app (Cmd+H) tira as janelas dele da fita; ao reaparecer, elas voltam à direita da focada.
- Se o processo morrer sem Ctrl+C, as janelas ficam estacionadas na borda. Rodar de novo (e sair com Ctrl+C) devolve.
