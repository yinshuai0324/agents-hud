#!/bin/bash
# 从 ui.c 自动提取所有非 ASCII 字符生成中文字体，避免漏字变"豆腐块"。
# 用法：cd esp32/main && bash gen_font.sh
set -euo pipefail
cd "$(dirname "$0")"

SYMBOLS=$(python3 - <<'EOF'
src = open('ui.c').read()
chars = sorted({c for c in src if ord(c) > 127})
print(''.join(chars), end='')
EOF
)

npx --yes lv_font_conv \
  --font "/System/Library/Fonts/Supplemental/Arial Unicode.ttf" \
  --size 20 --bpp 4 --format lvgl --no-compress \
  --range 0x20-0x7E \
  --symbols "$SYMBOLS" \
  -o font_cn_20.c

# lv_font_conv 生成的 include 路径不适配 IDF
python3 - <<'EOF'
s = open('font_cn_20.c').read().replace('#include "lvgl/lvgl.h"', '#include "lvgl.h"')
open('font_cn_20.c', 'w').write(s)
EOF

echo "font_cn_20.c regenerated ($(python3 -c "print(len('''$SYMBOLS'''))") symbols + ASCII)"
