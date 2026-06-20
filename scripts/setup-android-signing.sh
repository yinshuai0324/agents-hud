#!/usr/bin/env bash
#
# One-time setup of the Android release signing key for CI.
#
# Generates a keystore locally (gitignored — never committed), then stores it +
# its passwords as GitHub Actions secrets so the `android` workflow can sign the
# release APK with a STABLE key (required for in-app auto-update to overwrite an
# installed build). Re-run is safe; reuse the same keystore/password to keep the
# signature stable.
#
#   scripts/setup-android-signing.sh
#
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 1; }

REPO="yinshuai0324/agents-hud"
ALIAS="agentshud"
KS="agentshud-release.jks" # matches .gitignore

# Locate a WORKING keytool. Real JDKs first; the bare `keytool` on macOS is often
# the /usr/bin stub that has no runtime, so we verify each candidate actually runs.
KEYTOOL=""
candidates=(
  "${JAVA_HOME:-}/bin/keytool"
  "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"
)
sys_jh="$(/usr/libexec/java_home 2>/dev/null || true)"
[ -n "$sys_jh" ] && candidates+=("$sys_jh/bin/keytool")
candidates+=("$(command -v keytool 2>/dev/null || true)")
for c in "${candidates[@]}"; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  if "$c" -help >/dev/null 2>&1; then KEYTOOL="$c"; break; fi
done
[ -n "$KEYTOOL" ] || {
  echo "找不到可用的 keytool。Android Studio 自带 JDK，或 \`brew install openjdk\`。" >&2
  echo "也可手动指定：JAVA_HOME=/path/to/jdk scripts/setup-android-signing.sh" >&2
  exit 1
}
echo "使用 keytool：$KEYTOOL"

if [ -f "$KS" ]; then
  echo "复用已存在的 $KS（请输入它的密码）。"
  read -r -s -p "keystore 密码: " PASS; echo
else
  read -r -s -p "为新 keystore 设置密码: " PASS; echo
  read -r -s -p "再输入一次: " PASS2; echo
  [ "$PASS" = "$PASS2" ] || { echo "两次不一致。" >&2; exit 1; }
  [ -n "$PASS" ] || { echo "密码不能为空。" >&2; exit 1; }
  "$KEYTOOL" -genkeypair -v -keystore "$KS" -alias "$ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$PASS" -keypass "$PASS" \
    -dname "CN=AgentsHUD, OU=Dev, O=AgentsHUD, L=NA, S=NA, C=NA"
fi

B64=$(base64 < "$KS" | tr -d '\n')

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "==> 写入 GitHub Secrets（$REPO）..."
  printf '%s' "$B64"   | gh secret set ANDROID_KEYSTORE_BASE64   --repo "$REPO"
  printf '%s' "$PASS"  | gh secret set ANDROID_KEYSTORE_PASSWORD --repo "$REPO"
  printf '%s' "$ALIAS" | gh secret set ANDROID_KEY_ALIAS         --repo "$REPO"
  printf '%s' "$PASS"  | gh secret set ANDROID_KEY_PASSWORD      --repo "$REPO"
  echo "✅ 已设置 4 个 secrets。下次发版（推 v* tag）CI 就会用它签名。"
else
  cat <<EOF

未检测到已登录的 gh。请到 GitHub → 仓库 Settings → Secrets and variables → Actions
手动添加这 4 个 secret：

  ANDROID_KEYSTORE_PASSWORD = <你刚输入的密码>
  ANDROID_KEY_ALIAS         = $ALIAS
  ANDROID_KEY_PASSWORD      = <同一个密码>
  ANDROID_KEYSTORE_BASE64   = <下面整串>

----------------- ANDROID_KEYSTORE_BASE64 -----------------
$B64
-----------------------------------------------------------

（或先 \`gh auth login\` 再重跑本脚本自动写入。）
EOF
fi

echo "keystore 留在 ./${KS} （已被 .gitignore 忽略）。请妥善备份——丢了就无法再发布可覆盖更新的版本。"
