#!/system/bin/sh
# 安装提示与权限设置 (MODPATH 由 KernelSU 安装器提供)
ui_print "================================"
ui_print "  省电与限制发烫 (battery-cooler)"
ui_print "  均衡 / 超级省电 / 发烫限制 / 性能"
ui_print "  智能快充 75~90W 插电自动(最低75W)"
ui_print "  安装后请在 KernelSU 管理器打开"
ui_print "  模块的 WebUI 进行配置"
ui_print ""
ui_print "  作者：丫丫摄影作品"
ui_print "================================"

# 赋予脚本执行权限
for f in engine.sh service.sh action.sh customize.sh; do
    [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f"
done
chmod 0755 "$MODPATH" 2>/dev/null
exit 0
