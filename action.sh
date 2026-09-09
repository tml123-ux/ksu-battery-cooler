#!/system/bin/sh
# KernelSU 管理器中"动作"按钮: 一键在均衡/性能间快速切换
MODDIR=${0%/*}
DATA_DIR=/data/adb/battery-cooler
P="balanced"
if [ -f "$DATA_DIR/config.conf" ]; then
    P=$(grep -E '^profile=' "$DATA_DIR/config.conf" 2>/dev/null | cut -d= -f2)
fi
case "$P" in
    balanced|thermal|powersave)
        sh "$MODDIR/engine.sh" apply performance >/dev/null 2>&1
        echo "已切换到: 性能模式"
        ;;
    performance)
        sh "$MODDIR/engine.sh" apply balanced >/dev/null 2>&1
        echo "已切换到: 均衡模式"
        ;;
    *)
        sh "$MODDIR/engine.sh" apply balanced >/dev/null 2>&1
        echo "已切换到: 均衡模式"
        ;;
esac
exit 0
