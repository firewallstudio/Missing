#!/bin/bash
# Missing sürümünü yerelde imzalar ve GitHub Releases'e yayınlar.
#   ./release.sh            → VERSION'daki sürümü derle, imzala, doğrula, yayınla
#   ./release.sh --dry-run  → her şeyi yap ama yayınlama (Missing.zip proje klasöründe kalır)
#
# Gerekenler:
#   - Anahtar Zinciri'nde "Missing Code Signing" kimliği (signing-secrets/Missing.p12)
#   - gh (GitHub CLI), firewallstudio/Missing'e yazma yetkisi
#   - VERSION, CHANGELOG.md ve Sources/Changelog.swift güncel, commit'lenmiş ve push edilmiş
set -euo pipefail
cd "$(dirname "$0")"

REPO="firewallstudio/Missing"
IDENTITY="Missing Code Signing"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
fail() { echo "❌ $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Geçersiz VERSION: $VERSION"
command -v gh >/dev/null || fail "gh yok: brew install gh"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" \
  || security find-identity | grep -q "\"$IDENTITY\"" \
  || fail "Anahtar Zinciri'nde \"$IDENTITY\" yok. signing-secrets/Missing.p12 dosyasını çift tıklayıp ekle."

# Kod GitHub'dakiyle aynı olmalı: yayın, tag'in gösterdiği commit'ten derlenir
[[ -z "$(git status --porcelain -- Sources build.sh VERSION CHANGELOG.md Resources)" ]] \
  || fail "Commit'lenmemiş değişiklik var. Önce commit'le ve push et."
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "Yerel main ile origin/main farklı. Önce push et (ya da pull)."
grep -q "^## $VERSION\$" CHANGELOG.md || fail "CHANGELOG.md'de \"## $VERSION\" başlığı yok."
grep -q "version: \"$VERSION\"" Sources/Changelog.swift || fail "Sources/Changelog.swift'te $VERSION kaydı yok."
if [[ $DRY == 0 ]] && gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  fail "$TAG zaten yayında."
fi

# Tag yoksa oluştur ve gönder
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  git tag "$TAG"
  echo "▶ $TAG oluşturuldu"
fi
[[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || fail "$TAG başka bir commit'i gösteriyor."
if [[ $DRY == 0 ]]; then git push -q origin "$TAG" 2>/dev/null || true; fi

# Derle ve imzala
SIGN_IDENTITY="$IDENTITY" ./build.sh --universal --version "$VERSION"

# Güncelleyicinin ve install.sh'in kuralıyla doğrula
REQ="$(sed -n "s/^REQ='\(.*\)'$/\1/p" install.sh)"
[[ -n "$REQ" ]] || fail "install.sh'te REQ bulunamadı."
codesign --verify --deep --strict -R "=$REQ" Missing.app || fail "İmza, güncelleyicinin kuralına uymuyor."
[[ "$(defaults read "$PWD/Missing.app/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" ]] || fail "Paketteki sürüm $VERSION değil."
echo "✔ İmza doğrulandı ($IDENTITY)"

# Temiz zip: ._ / __MACOSX olmasın (düz unzip ile açınca imza bozulmasın)
rm -f Missing.zip
xattr -cr Missing.app
ditto -c -k --norsrc --noextattr --noqtn --keepParent Missing.app Missing.zip
if unzip -Z1 Missing.zip | grep -qE '(^|/)\._|__MACOSX|\.DS_Store'; then fail "Zip'te ._ / __MACOSX / .DS_Store var."; fi
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
unzip -q Missing.zip -d "$CHECK"
codesign --verify --deep --strict -R "=$REQ" "$CHECK/Missing.app" || fail "Zip'ten açılan uygulamanın imzası geçersiz."
echo "✔ Missing.zip hazır ($(du -h Missing.zip | cut -f1 | tr -d ' '))"

if [[ $DRY == 1 ]]; then
  echo "ℹ︎ --dry-run: yayınlanmadı. Missing.app ve Missing.zip proje klasöründe."
  exit 0
fi

# Notlar: CHANGELOG.md'deki bu sürümün maddeleri
PREV="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
NOTES="$(mktemp)"
awk -v v="## $VERSION" '$0==v {on=1; next} on && /^## / {exit} on {print}' CHANGELOG.md | sed '/^[[:space:]]*$/d' > "$NOTES"
if [[ -n "$PREV" ]]; then
  printf '\n**Full Changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREV" "$TAG" >> "$NOTES"
fi

gh release create "$TAG" Missing.zip -R "$REPO" --verify-tag --title "Missing $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
rm -rf Missing.app Missing.zip
echo "✅ Missing $VERSION yayında: https://github.com/$REPO/releases/tag/$TAG"
