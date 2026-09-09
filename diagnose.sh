#!/usr/bin/env sh
# vivo X300pro (天玑9500) 设备诊断脚本
# 用法: su -c "sh /path/to/diagnose.sh"
# 用于收集 CPU 架构和温控节点信息，便于后续适配

echo "=== 设备信息 ==="
echo "型号: vivo X300pro (V2502A)"
echo "处理器: 天玑9500 (MediaTek Dimensity 9500)"
cat /proc/version 2>/dev/null
echo ""

echo "=== SoC 信息 ==="
cat /sys/devices/soc0/soc_id 2>/dev/null
cat /sys/devices/soc0/hw_version 2>/dev/null
echo ""

echo "=== CPU 架构 ==="
grep -E "^processor|^Hardware|^CPU part|^CPU architecture|^Model name" /proc/cpuinfo 2>/dev/null | head -20
echo ""

echo "=== 核心数量 ==="
echo "在线核心: $(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
echo "总核心: $(nproc 2>/dev/null)"
echo ""

echo "=== cpufreq 层级分析 ==="
# 按频率排序核心
for d in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    cpu=${d##*/cpu}
    online=$(cat /sys/devices/system/cpu/$cpu/online 2>/dev/null)
    maxf=$(cat $d/cpuinfo_max_freq 2>/dev/null)
    cur=$(cat $d/scaling_cur_freq 2>/dev/null)
    minf=$(cat $d/scaling_min_freq 2>/dev/null)
    policy=$(cat $d/scaling_governor 2>/dev/null)
    echo "  cpu${cpu}: online=${online} min=${minf}Hz cur=${cur}Hz max=${maxf}Hz policy=${policy}"
done
echo ""

echo "=== 频率档位统计 ==="
# 统计不同频率层级的核心数
_freq_list=""
for d in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    cpu=${d##*/cpu}
    maxf=$(cat $d/cpuinfo_max_freq 2>/dev/null)
    [ -n "$maxf" ] && _freq_list="$_freq_list $maxf"
done
echo "$_freq_list" | tr ' ' '\n' | sort -n | uniq -c | while read cnt freq; do
    [ -n "$freq" ] && echo "  ${freq} Hz: $cnt 个核心"
done
echo ""

echo "=== 温控节点 ==="
echo "--- thermal_zone 列表 ---"
for f in /sys/class/thermal/thermal_zone*/type; do
    [ -r "$f" ] || continue
    z=$(dirname "$f" | sed 's|.*/thermal_zone||')
    t=$(cat "$f" 2>/dev/null | tr -d '\0')
    tmp=$(cat "${f%/type}/temp" 2>/dev/null)
    mode=$(cat "${f%/type}/mode" 2>/dev/null)
    echo "  zone${z}: $t = ${tmp} (mode=${mode:-N/A})"
done
echo ""

echo "--- 所有温度相关节点原始值 ---"
for f in /sys/class/thermal/thermal_zone*/temp \
         /sys/class/power_supply/battery/temp \
         /sys/class/power_supply/battery/temp_input \
         /sys/class/power_supply/battery/temp_alarm; do
    [ -r "$f" ] || continue
    val=$(cat "$f" 2>/dev/null)
    echo "  $f = $val"
done
echo ""

echo "--- 联发科特定温控路径 ---"
for f in \
    /sys/devices/platform/mtktspmi*/thermal*/temp \
    /sys/devices/platform/mtk-thermal/temp \
    /sys/kernel/debug/thermal/status \
    /proc/mt_thermal
do
    [ -r "$f" ] && echo "  $f: $(cat "$f" 2>/dev/null | head -c 200)"
done
echo ""

echo "--- cdev 温度 (联发科) ---"
for f in /sys/class/thermal/thermal_zone*/cdev0_temp; do
    [ -r "$f" ] && echo "  $(dirname "$f" | sed 's|.*/thermal_zone||'): $(cat "$f" 2>/dev/null)"
done
echo ""

echo "=== 电池温度 ==="
[ -r /sys/class/power_supply/battery/temp ] && \
    echo "  battery/temp: $(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
[ -r /sys/class/power_supply/battery/temp_unit ] && \
    echo "  battery/temp_unit: $(cat /sys/class/power_supply/battery/temp_unit 2>/dev/null)"
echo ""

echo "=== 当前温控守护状态 ==="
if [ -f /data/adb/battery-cooler/state ]; then
    cat /data/adb/battery-cooler/state
else
    echo "未安装 battery-cooler 模块或数据目录不存在"
fi
echo ""

echo "=== 建议 ==="
echo "请确认以下信息以便进一步优化适配："
echo "1. 哪个 thermal_zone 的温度变化与机身发热最同步？"
echo "2. 是否有 mtktspmi 或 mtk-thermal 相关路径？"
echo "3. cpufreq 层级是否为 1+3+4 或 2+2+4 配置？"
