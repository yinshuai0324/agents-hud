#!/usr/bin/env bash
#
# Release helper for AgentsHUD.
#
#   scripts/release.sh [patch|minor|major|X.Y.Z] [--dry-run]
#
# Bumps server/package.json, commits + tags vX.Y.Z, pushes, then downloads the
# GitHub tag tarball, computes its sha256, and rewrites Formula/agents-hud.rb
# (url + sha256 + version) and pushes that too. Default bump is `patch`.
#
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 1; }

REPO="yinshuai0324/agents-hud"
PKG="server/package.json"
FORMULA="Formula/agents-hud.rb"

info() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }
die()  { printf "\033[1;31mx\033[0m  %s\n" "$1" >&2; exit 1; }

DRY=0
args=()
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY=1 ;;
    *) args+=("$a") ;;
  esac
done
arg="${args[0]:-patch}"

[ -f "$PKG" ] && [ -f "$FORMULA" ] || die "找不到 $PKG / $FORMULA，请在仓库根运行。"
command -v node >/dev/null 2>&1 || die "需要 node。"

cur=$(node -p "require('./$PKG').version")
case "$arg" in
  major|minor|patch)
    IFS=. read -r MA MI PA <<<"$cur"
    case "$arg" in
      major) MA=$((MA + 1)); MI=0; PA=0 ;;
      minor) MI=$((MI + 1)); PA=0 ;;
      patch) PA=$((PA + 1)) ;;
    esac
    new="$MA.$MI.$PA" ;;
  [0-9]*.[0-9]*.[0-9]*) new="$arg" ;;
  *) die "用法: scripts/release.sh [patch|minor|major|X.Y.Z] [--dry-run]" ;;
esac
tag="v$new"

info "当前 $cur → 新版本 $new ($tag)$([ $DRY = 1 ] && echo '   [dry-run]')"

if [ $DRY = 1 ]; then
  cat <<EOF
将执行：
  1) 写入 $PKG 版本 $new → commit "chore: release $tag" + 打 tag $tag
  2) git push && git push origin $tag
  3) 下载 $tag 的 tarball 计算 sha256
  4) 改写 $FORMULA 的 url/sha256/version → commit + push
EOF
  exit 0
fi

# --- preflight ---
[ -z "$(git status --porcelain)" ] || die "工作区有未提交改动，请先提交或清理。"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "请在 main 分支发版。"
git rev-parse "$tag" >/dev/null 2>&1 && die "tag $tag 已存在。"

# --- bump + commit + tag (plain git; npm version proved unreliable here) ---
info "bump + commit + tag ..."
perl -0pi -e "s{(\"version\":\s*\")[0-9.]+(\")}{\${1}$new\${2}}" "$PKG"
grep -q "\"version\": \"$new\"" "$PKG" || die "未能写入新版本号到 $PKG。"
git add "$PKG"
git commit -q -m "chore: release $tag"
git tag -a "$tag" -m "$tag"

info "推送 commit + tag ..."
git push
git push origin "$tag"

# --- fetch tarball + sha256 ---
url="https://github.com/$REPO/archive/refs/tags/$tag.tar.gz"
info "下载并计算 sha256：$url"
tmp=$(mktemp)
sha=""
for _ in 1 2 3 4 5; do
  if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then sha=$(shasum -a 256 "$tmp" | awk '{print $1}'); fi
  [ -n "$sha" ] && break
  sleep 3
done
rm -f "$tmp"
[ -n "$sha" ] || die "下载 tarball 失败（GitHub 可能还在生成，稍后可手动重试）。"
info "sha256: $sha"

# --- rewrite formula ---
info "更新 $FORMULA ..."
perl -0pi -e "s{url \"https://github\.com/\Q$REPO\E/archive/refs/tags/v[0-9.]+\.tar\.gz\"}{url \"$url\"}" "$FORMULA"
perl -0pi -e "s{sha256 \"[0-9a-f]{64}\"}{sha256 \"$sha\"}" "$FORMULA"
perl -0pi -e "s{version \"[0-9.]+\"}{version \"$new\"}" "$FORMULA"

git add "$FORMULA"
git commit -q -m "chore: bump formula to $tag"
git push

info "✅ 已发布 $tag"
echo "  本机升级：agents-hud update"
