#!/bin/sh
# Publica uma versão: ./scripts/release.sh 0.1.0 "o que mudou"
# Monta o app (scripts/app.sh), marca o código com a tag, cria a release no repo público (o NiriOS instalado vê a
# versão nova na próxima conferência diária, e as notas aparecem na janela do update) e atualiza o cask no tap.
set -eu
VERSION=${1:?"uso: scripts/release.sh <versão> <notas>"}
NOTES=${2:?"uso: scripts/release.sh <versão> <notas>"}
REPO=deandevz/niri-os-releases
cd "$(dirname "$0")/.."
TAP=${NIRI_TAP:-"$(cd .. && pwd)/homebrew-tap"}

[ -z "$(git status --porcelain)" ] || { echo "commit antes: a tag aponta pro código da release"; exit 1; }
[ -f "$TAP/Casks/niri-os.rb" ] || { echo "sem $TAP/Casks/niri-os.rb (NIRI_TAP aponta pro tap)"; exit 1; }
./scripts/app.sh "$VERSION"
ZIP=.build/dist/NiriOS-$VERSION.zip
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "NiriOS $VERSION" --notes "$NOTES"

sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/niri-os.rb"
git -C "$TAP" add Casks/niri-os.rb
git -C "$TAP" commit -m "NiriOS $VERSION"
git -C "$TAP" push
echo "publicado: https://github.com/$REPO/releases/tag/v$VERSION"
