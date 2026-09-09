#!/usr/bin/env sh
# 打包 KernelSU 模块为可安装 zip
set -e
cd "$(dirname "$0")"

VER=$(grep -E '^version=' module.prop | cut -d= -f2)
OUT="battery-cooler-${VER}.zip"

rm -f "$OUT"
# zip 根必须包含 module.prop/customize.sh 等(不含 README/build 脚本)
zip -r -X "$OUT" module.prop customize.sh service.sh action.sh engine.sh webroot diagnose.sh \
    -x '*.DS_Store' >/dev/null

echo "已生成: $OUT"
echo "推到手机后在 KernelSU 管理器中从本地安装即可"
