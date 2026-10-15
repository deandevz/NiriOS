#!/bin/sh
# Testes do núcleo (layout + mola). Só com Command Line Tools o Swift Testing fica fora do caminho padrão.
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
cd "$(dirname "$0")/.." && exec swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
