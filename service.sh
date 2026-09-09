#!/system/bin/sh
# 开机 late_start 阶段: 应用档位并拉起温控守护
MODDIR=${0%/*}
[ -f "$MODDIR/engine.sh" ] || exit 0
sh "$MODDIR/engine.sh" boot
exit 0
