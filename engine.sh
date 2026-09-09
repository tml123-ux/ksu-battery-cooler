#!/system/bin/sh
#============================================================#
#  battery-cooler engine
#  省电与限制发烫 多档位引擎
#  用法:
#    engine.sh init             初始化数据目录与默认配置
#    engine.sh apply <profile>  应用档位并持久化
#    engine.sh boot             开机应用(按配置决定是否启用监控)
#    engine.sh daemon           温控守护(前台循环, 由 service 调起)
#    engine.sh stop-daemon      停止温控守护
#    engine.sh get              输出 JSON 状态(供 WebUI)
#    engine.sh set <key> <val>  写配置项并即时生效
#============================================================#

MODID=battery-cooler
# 脚本自身目录即模块目录
MODDIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
[ -z "$MODDIR" ] && MODDIR=/data/adb/modules/$MODID

# 数据目录与 sysfs 根路径均可通过环境变量覆盖(便于本地测试)
DATA_DIR=${BC_DATA_DIR:-/data/adb/$MODID}
SYS=${BC_SYS:-/sys}
CONF=$DATA_DIR/config.conf
STATE=$DATA_DIR/state
LOG=$DATA_DIR/monitor.log
PIDFILE=$DATA_DIR/monitor.pid

# ---------------- 配置默认值 ----------------
# vivo X300pro (V2502A) 适配: 温度超过 40°C 即触发降频
default_conf() {
    printf '%s\n' \
        'profile=balanced' \
        'thermal_enabled=1' \
        'screen_auto=1' \
        'thermal_limit=40' \
        'thermal_recover=37' \
        'poll_ms=5000' \
        'boot_apply=1' \
        'charge_limit=1' \
        'charge_auto=0' \
        'charge_target_w=90' \
        'charge_current=3000000' \
        'charge_voltage=4400000'
}

# ---------------- 基础工具 ----------------
log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }

# 读配置: get_conf <key> <default>
get_conf() {
    local k="$1" d="${2:-}" v
    [ -f "$CONF" ] || return 0
    v=$(grep -E "^$k=" "$CONF" 2>/dev/null | head -n1 | cut -d= -f2-)
    [ -n "$v" ] && echo "$v" || echo "$d"
}

# 写配置: set_conf <key> <val>
set_conf() {
    local k="$1" v="$2"
    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    if [ -f "$CONF" ] && grep -qE "^$k=" "$CONF" 2>/dev/null; then
        sed -i "s|^$k=.*|$k=$v|" "$CONF"
    else
        echo "$k=$v" >> "$CONF"
    fi
    chmod 600 "$CONF" 2>/dev/null
}

# init
init() {
    mkdir -p "$DATA_DIR"
    if [ ! -f "$CONF" ]; then
        default_conf > "$CONF"
        chmod 600 "$CONF"
        echo "default config created"
    fi
    [ ! -f "$STATE" ] && echo "{}" > "$STATE"
    [ ! -f "$LOG" ] && : > "$LOG"
    chmod 600 "$STATE" "$LOG" 2>/dev/null
}

# ---------------- 温度读取 ----------------
# 折成 0.1°C 整数返回, 便于 shell 运算
# vivo X300pro 适配: 优先读取 battery/temp 和 thermal_zone0(通常是 CPU 或 SoC 温度)
# 天玑9500 适配: 额外支持联发科温控路径
# 温度合法性校验: 手机正常温度范围 -10°C 到 80°C (超出视为传感器故障)
# 单位判定: < 1000 视为 0.1°C 单位, >= 1000 视为 0.001°C 单位
read_temp_raw() {
    local f v t max=0 raw_count=0
    for f in \
        $SYS/class/power_supply/battery/temp \
        $SYS/class/thermal/thermal_zone*/temp
    do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null) || continue
        case "$v" in
            ''|*[!0-9]*) continue ;;
        esac
        # 单位判定
        if [ "$v" -lt 100 ]; then continue  # 无效值
        elif [ "$v" -ge 1000 ]; then t=$((v / 100))  # 0.001°C → 0.1°C
        else t=$v; fi  # 0.1°C 单位直接使用
        # 合理温度范围校验: 10°C 到 60°C (手机正常工作温度)
        if [ "$t" -ge 100 ] && [ "$t" -le 600 ]; then
            [ "$t" -gt "$max" ] && max=$t
            raw_count=$((raw_count + 1))
        fi
    done
    # 联发科天玑系列可能的额外路径
    for f in \
        $SYS/class/thermal/thermal_zone*/cdev0_temp \
        $SYS/devices/platform/mtktspmi*/thermal*/temp \
        $SYS/devices/platform/mtk-thermal/temp \
        $SYS/kernel/debug/thermal/status
    do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null) || continue
        case "$v" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$v" -lt 100 ]; then continue
        elif [ "$v" -ge 1000 ]; then t=$((v / 100))
        else t=$v; fi
        # 合理温度范围校验: 10°C 到 60°C
        if [ "$t" -ge 100 ] && [ "$t" -le 600 ]; then
            [ "$t" -gt "$max" ] && max=$t
            raw_count=$((raw_count + 1))
        fi
    done
    if [ "$raw_count" -eq 0 ]; then
        log "warn: 未找到有效温度读数, 请运行 temp_debug 诊断"
    fi
    [ "$max" -gt 0 ] && echo "$max" || echo "0"
}

# ---------------- 屏幕状态 ----------------
# 输出: 1=亮屏 0=灭屏
# 判定优先级: 环境变量 BC_SCREEN_FILE(mock) > 亮度节点 > dumpsys power > 默认亮屏
screen_is_on() {
    local v b found=0 on=0 f
    # 调试/测试覆盖: BC_SCREEN_FILE 文件内容 0/1
    if [ -n "$BC_SCREEN_FILE" ] && [ -f "$BC_SCREEN_FILE" ]; then
        v=$(cat "$BC_SCREEN_FILE" 2>/dev/null)
        case "$v" in
            0) echo 0; return 0 ;;
            1) echo 1; return 0 ;;
        esac
    fi
    # 亮度节点法(低开销, 无需 binder)
    for b in $SYS/class/backlight/*/brightness $SYS/class/leds/lcd-backlight/brightness; do
        [ -r "$b" ] || continue
        found=1
        v=$(cat "$b" 2>/dev/null | tr -d ' \n\r')
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -gt 0 ] 2>/dev/null && on=1
    done
    if [ "$found" = "1" ]; then
        [ "$on" = "1" ] && echo 1 || echo 0
        return 0
    fi
    # 权威方式: dumpsys power 唤醒状态
    if command -v dumpsys >/dev/null 2>&1; then
        v=$(dumpsys power 2>/dev/null | grep -o 'mWakefulness=[A-Za-z]*' | head -n1 | cut -d= -f2)
        case "$v" in
            Awake|Dreaming) echo 1; return 0 ;;
            Asleep|Dozing|LightDoze|DeepDoze|OFF) echo 0; return 0 ;;
        esac
    fi
    # 无法判定 -> 默认亮屏(不误触省电)
    echo 1
}

# ---------------- 充电控制 ----------------
# 探测可用的充电控制路径
# 返回路径列表（空格分隔）
detect_charge_paths() {
    local paths=""
    for f in \
        $SYS/class/power_supply/battery/current_max \
        $SYS/class/power_supply/battery/input_current_limit \
        $SYS/class/power_supply/battery/constant_charge_current \
        $SYS/class/power_supply/battery/fastcharge \
        $SYS/class/power_supply/battery/input_power_limit \
        $SYS/class/power_supply/battery/power_max \
        $SYS/class/power_supply/battery/voltage_max \
        $SYS/class/power_supply/battery/constant_charge_voltage \
        $SYS/class/power_supply/battery/icl \
        $SYS/class/power_supply/battery/charge_enabled
    do
        [ -w "$f" ] && paths="$paths $f"
    done
    echo "$paths"
}

# 设置充电电流 (单位: uA)
set_charge_current() {
    local current="$1"
    [ -z "$current" ] && { echo "usage: set_charge_current <microamps>"; exit 1; }
    case "$current" in ''|*[!0-9]*) echo "invalid value"; exit 1 ;; esac
    init
    local paths written=0
    paths=$(detect_charge_paths)
    for f in $paths; do
        case "$f" in
            *current*|*icl*)
                echo "$current" > "$f" 2>/dev/null && written=$((written+1))
                ;;
        esac
    done
    set_conf charge_current "$current"
    echo "set charge_current=$current (written=$written paths)"
}

# 设置充电电压 (单位: uV)
set_charge_voltage() {
    local voltage="$1"
    [ -z "$voltage" ] && { echo "usage: set_charge_voltage <microvolts>"; exit 1; }
    case "$voltage" in ''|*[!0-9]*) echo "invalid value"; exit 1 ;; esac
    init
    local paths written=0
    paths=$(detect_charge_paths)
    for f in $paths; do
        case "$f" in
            *voltage*|*charge_voltage*)
                echo "$voltage" > "$f" 2>/dev/null && written=$((written+1))
                ;;
        esac
    done
    set_conf charge_voltage "$voltage"
    echo "set charge_voltage=$voltage (written=$written paths)"
}

# 启用/禁用充电限制
toggle_charge_limit() {
    local enable="$1"
    case "$enable" in
        0|1) ;;
        *) echo "usage: toggle_charge_limit <0|1>"; exit 1 ;;
    esac
    init
    local paths written=0
    paths=$(detect_charge_paths)
    for f in $paths; do
        case "$f" in
            *fastcharge*|*charge_enabled*)
                echo "$enable" > "$f" 2>/dev/null && written=$((written+1))
                ;;
        esac
    done
    set_conf charge_limit "$enable"
    echo "charge_limit=$enable (written=$written paths)"
}

# ---------------- 充电功率自动调节 ----------------
# 设计目标: 插电后按电池温度自动调节请求功率, 范围 75W~charge_target_w(90W 上限),
#           温度越高功率越低, 最低保持 75W, 温度回落恢复目标功率
# 温度区间: <= 36.0°C 给满目标功率; >= 46.0°C 给最低 75W; 中间线性回落
AUTO_COOL_T=360   # 36.0°C
AUTO_HOT_T=460    # 46.0°C
AUTO_MIN_W=75     # 最低保持功率

# 功率(W) -> 电流(uA), 按 4.4V 电池端折算 (与原 charge_fast 一致)
power_w_to_ua() {
    local w="$1"
    echo "$(( w * 10000000 / 44 ))"
}

# 检测是否正在充电/插电: 0=否 1=是
# 优先级: 环境变量 BC_CHARGER_FILE(mock) > battery/status > online 节点
charge_online() {
    local v f
    if [ -n "$BC_CHARGER_FILE" ] && [ -f "$BC_CHARGER_FILE" ]; then
        v=$(cat "$BC_CHARGER_FILE" 2>/dev/null | tr -d ' \n\r')
        case "$v" in 0) echo 0; return 0 ;; 1) echo 1; return 0 ;; esac
    fi
    if [ -r "$SYS/class/power_supply/battery/status" ]; then
        v=$(cat "$SYS/class/power_supply/battery/status" 2>/dev/null)
        case "$v" in
            *Charging*|*charging*) echo 1; return 0 ;;
        esac
    fi
    for f in $SYS/class/power_supply/*/online; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null | tr -d ' \n\r')
        [ "$v" = "1" ] && { echo 1; return 0; }
    done
    echo 0
}

# 按温度计算请求功率(W): 温度 -> 目标与最低之间的线性回落
charge_power_for_temp() {
    local t="$1" target_w="$2" span range diff
    [ -z "$target_w" ] && target_w=90
    [ "$target_w" -lt "$AUTO_MIN_W" ] 2>/dev/null && target_w="$AUTO_MIN_W"
    [ "$target_w" -gt 90 ] 2>/dev/null && target_w=90
    [ -z "$t" ] && t=0
    if [ "$t" -le "$AUTO_COOL_T" ] 2>/dev/null; then
        echo "$target_w"; return 0
    fi
    if [ "$t" -ge "$AUTO_HOT_T" ] 2>/dev/null; then
        echo "$AUTO_MIN_W"; return 0
    fi
    # 线性回落: 在 cool..hot 之间从 target_w 降到 75W
    span=$(( AUTO_HOT_T - AUTO_COOL_T ))
    range=$(( target_w - AUTO_MIN_W ))
    diff=$(( t - AUTO_COOL_T ))
    echo "$(( target_w - range * diff / span ))"
}

# 按指定功率(W)写入充电请求: 换算 uA -> 写电流/电压节点并记入配置
apply_charge_power_w() {
    local w="$1" ua
    [ -z "$w" ] && return 1
    init
    ua=$(power_w_to_ua "$w")
    set_charge_current "$ua"
    set_charge_voltage 4400000
    toggle_charge_limit 1
    set_conf charge_power_w "$w"
}

# 按当前温度请求一次功率(供手动命令): 返回并应用功率
apply_charge_auto_once() {
    init
    local t target_w w ua
    t=$(read_temp_raw)
    target_w=$(get_conf charge_target_w 90)
    w=$(charge_power_for_temp "$t" "$target_w")
    ua=$(power_w_to_ua "$w")
    set_charge_current "$ua"
    set_charge_voltage 4400000
    toggle_charge_limit 1
    set_conf charge_target_w "$target_w"
    set_conf charge_power_w "$w"
    echo "auto charge applied: ${w}W / ${ua}uA (temp $(fmt_temp $t)°C)"
}

# 充电状态
get_charge_status() {
    local status=""
    for f in /sys/class/power_supply/battery/*; do
        [ -r "$f" ] || continue
        local name=$(basename "$f")
        local val=$(cat "$f" 2>/dev/null)
        [ -n "$val" ] && status="$status $name=$val"
    done
    echo "$status"
}

# 温度显示: 362 => 36.2
fmt_temp() { echo "$(( $1 / 10 )).$(( $1 % 10 ))"; }

# ---------------- CPU 频率限制 ----------------
# 每个在线核按其所在频率层(小/中/大核)套用档位比例
# 返回受限核数, 结果记入日志
# 天玑9500: 通常为 1+3+4 架构或 2+2+4 架构
PROFILE_PCT="balanced:100:100:100|powersave:80:65:55|thermal:60:45:40|performance:100:100:100"

profile_pct() { # <profile> <level 0/1/2>
    local p="$1" l="$2" row
    row=$(echo "$PROFILE_PCT" | tr '|' '\n' | grep -E "^$p:" | head -n1)
    echo "$row" | cut -d: -f$((l + 2))
}

collect_levels() { # 输出升序去重后的 cpuinfo_max_freq 层级列表
    local d maxf out=""
    for d in $SYS/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -e "$d/cpuinfo_max_freq" ] || continue
        maxf=$(cat "$d/cpuinfo_max_freq" 2>/dev/null) || continue
        case "$maxf" in ''|*[!0-9]*) continue ;; esac
        case " $out " in *" $maxf "*) ;; *) out="$out $maxf" ;; esac
    done
    echo "$out" | tr ' ' '\n' | grep -v '^$' | sort -n
}

freq_level_index() { # <freq> ; 依据 collect_levels 结果, 返回 0..n
    local freq="$1" i=0
    for f in $(collect_levels); do
        if [ "$freq" = "$f" ]; then echo "$i"; return 0; fi
        i=$((i+1))
    done
    echo 0
}

# 在可用频率列表里挑 <= target 的最大值
pick_freq() { # <target> <avail_list...>
    local target="$1" best=0 a
    shift
    for a in "$@"; do
        [ "$a" -le "$target" ] && [ "$a" -gt "$best" ] && best=$a
    done
    [ "$best" -gt 0 ] && echo "$best" || echo "$target"
}

apply_profile() { # <profile>
    local profile="$1" pct now
    local cpu d maxf level pctf target chosen av maxf_cur written n err newval
    n=0; err=0
    for d in $SYS/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -d "$d" ] || continue
        cpu=${d%/cpufreq}; cpu=${cpu#$SYS/devices/system/cpu/}
        # 仅限在线核
        [ -f "$SYS/devices/system/cpu/$cpu/online" ] && \
            [ "$(cat $SYS/devices/system/cpu/$cpu/online 2>/dev/null)" = "0" ] && continue
        [ -w "$d/scaling_max_freq" ] || { err=$((err+1)); continue; }
        maxf=$(cat "$d/cpuinfo_max_freq" 2>/dev/null || echo 0)
        case "$maxf" in ''|*[!0-9]*) continue ;; esac
        [ "$maxf" -eq 0 ] && continue
        level=$(freq_level_index "$maxf")
        pctf=$(profile_pct "$profile" "$level")
        [ -z "$pctf" ] && pctf=100
        target=$(( maxf * pctf / 100 ))
        # 从 available 挑最接近且 <= target 的频率; 无列表则直接写 target
        av=$(cat "$d/scaling_available_frequencies" 2>/dev/null)
        if [ -n "$av" ]; then
            chosen=$(pick_freq "$target" $av)
        else
            chosen=$target
        fi
        # 低于当前 scaling_min_freq 则抬到 min, 否则内核拒绝
        maxf_cur=$(cat "$d/scaling_min_freq" 2>/dev/null || echo 0)
        [ "$maxf_cur" -gt "$chosen" ] && chosen=$maxf_cur
        echo "$chosen" > "$d/scaling_max_freq" 2>/dev/null \
            && n=$((n+1)) \
            || err=$((err+1))
        written=$(cat "$d/scaling_max_freq" 2>/dev/null)
        [ "$written" != "$chosen" ] && log "warn: $cpu 目标 $chosen 实际 $written"
    done
    log "apply profile=$profile ok=$n skip/fail=$err"
    echo "applied $profile (ok=$n, skip=$err)"
}

# ---------------- 温控 + 待机 + 充电守护 ----------------
# 后台循环, 临时降档 + 插电自动充电调节:
#  1) 温控: 温度 >= limit 时(除 thermal 档外)临时压到 thermal 档;
#            温度回落到 recover 以下后解除。
#  2) 待机: 屏幕熄灭且 screen_auto=1 时临时压到 powersave 档;
#            亮屏后恢复。
#  3) 充电: charge_auto=1 且插电充电时, 按电池温度在 75W~charge_target_w
#            之间自动请求功率(温度越高越低, 最低保底 75W)。
# 优先级: 温控 override > 待机 screen > 用户档位(profile)
# 温控与充电调节相互独立(charge_auto 不依赖 thermal_enabled)

# 是否仍需要守护运行(任一特性开启)
daemon_needed() {
    local a b c
    a=$(get_conf thermal_enabled 1)
    b=$(get_conf screen_auto 1)
    c=$(get_conf charge_auto 0)
    { [ "$a" = "1" ] || [ "$b" = "1" ] || [ "$c" = "1" ]; } && { echo 1; return 0; }
    echo 0
}

# 按当前配置启停守护
update_daemon() {
    if [ "$(daemon_needed)" = "1" ]; then
        start_daemon
    else
        stop_daemon
    fi
}

daemon_loop() {
    local en sa ca limit recover poll profile temp override screen
    local screen_auto screen_on prev_profile applied prev_applied
    local new_override new_screen desired logmsg
    local chg_auto online prev_online last_w cur_w
    if [ "$(daemon_needed)" != "1" ]; then
        log "daemon: 温控/待机/充电均关闭, 退出"
        exit 0
    fi
    log "daemon: 启动 thermal_enabled=$(get_conf thermal_enabled 1) screen_auto=$(get_conf screen_auto 1) charge_auto=$(get_conf charge_auto 0)"
    prev_online=""
    last_w=""
    while :; do
        limit=$(get_conf thermal_limit 40)
        recover=$(get_conf thermal_recover 37)
        poll=$(get_conf poll_ms 5000)
        profile=$(get_conf profile balanced)
        en=$(get_conf thermal_enabled 1)
        sa=$(get_conf screen_auto 1)
        ca=$(get_conf charge_auto 0)
        temp=$(read_temp_raw)
        override="0"; screen="0"; prev_profile="$profile"; prev_applied="$profile"
        # 读取守护上次写入的状态
        if [ -f "$STATE" ]; then
            override=$(grep -o '"override":"[0-9]*"' "$STATE" | head -n1 | cut -d'"' -f4)
            screen=$(grep -o '"screen":"[0-9]*"' "$STATE" | head -n1 | cut -d'"' -f4)
            prev_profile=$(grep -o '"profile":"[^"]*"' "$STATE" | head -n1 | cut -d'"' -f4)
            prev_applied=$(grep -o '"applied":"[^"]*"' "$STATE" | head -n1 | cut -d'"' -f4)
        fi
        [ -z "$override" ] && override="0"
        [ -z "$screen" ] && screen="0"
        [ -z "$prev_applied" ] && prev_applied="$profile"
        # 温控与待机仅在各自开关开启时管理; 否则复位状态, 交由用户档位
        if [ "$en" != "1" ]; then new_override="0"; new_screen="0"; screen_auto="0"
        else
            # 用户手动切换档位 -> 重置守护状态, 以新档为基准重新评估
            if [ "$profile" != "$prev_profile" ]; then
                override=0; screen=0
                log "daemon: 检测到档位切换 -> $profile, 重置守护状态"
            fi
            # 计算新温控状态(带迟滞: 升温到 limit 触发, 降温到 recover 解除)
            new_override="$override"
            if [ "$temp" -gt 0 ] && [ "$profile" != "thermal" ]; then
                if [ "$temp" -ge $((limit * 10)) ] && [ "$new_override" != "1" ]; then
                    new_override=1
                    logmsg="daemon: 过热 $(fmt_temp $temp)°C >= ${limit}°C, 进入 thermal 档"
                elif [ "$temp" -le $((recover * 10)) ] && [ "$new_override" = "1" ]; then
                    new_override=0
                    logmsg="daemon: 回落 $(fmt_temp $temp)°C <= ${recover}°C, 解除温控降档"
                fi
            fi
            # 计算待机状态
            new_screen="$screen"
            if [ "$sa" = "1" ]; then
                screen_on=$(screen_is_on)
                if [ "$screen_on" = "0" ]; then
                    # 灭屏且未处于温控降档 -> 进入待机省电
                    if [ "$new_override" != "1" ] && [ "$new_screen" != "1" ]; then
                        new_screen=1
                        logmsg="daemon: 屏幕熄灭, 进入待机超级省电"
                    fi
                else
                    # 亮屏 -> 解除待机省电
                    if [ "$new_screen" = "1" ]; then
                        new_screen=0
                        logmsg="daemon: 屏幕点亮, 退出待机省电"
                    fi
                fi
            else
                new_screen=0
            fi
        fi
        # 计算实际生效档位: 温控 > 待机 > 用户档
        desired="$profile"
        [ "$new_screen" = "1" ] && desired="powersave"
        [ "$new_override" = "1" ] && desired="thermal"
        if [ "$desired" != "$prev_applied" ]; then
            apply_profile "$desired" >/dev/null 2>&1
            log "$logmsg (-> $desired)"
        fi
        # 充电功率自动调节
        if [ "$ca" = "1" ]; then
            online=$(charge_online)
            if [ "$online" = "1" ]; then
                # 插电中: 按当前温度求请求功率, 变化时写入
                cur_w=$(charge_power_for_temp "$temp" "$(get_conf charge_target_w 90)")
                if [ "$cur_w" != "$last_w" ] || [ "$online" != "$prev_online" ]; then
                    apply_charge_power_w "$cur_w"
                    log "daemon: 插电自动调节 -> ${cur_w}W (temp $(fmt_temp $temp)°C)"
                    last_w="$cur_w"
                fi
            elif [ "$online" != "$prev_online" ]; then
                log "daemon: 已拔出电源, 停止自动充电调节"
                last_w=""
            fi
            prev_online="$online"
        else
            prev_online=""
            last_w=""
        fi
        echo "{\"profile\":\"$profile\",\"override\":\"$new_override\",\"screen\":\"$new_screen\",\"applied\":\"$desired\",\"temperature\":\"$temp\",\"limit\":\"$limit\",\"recover\":\"$recover\",\"chg_auto\":\"$ca\",\"charging\":\"${online:-0}\",\"chg_w\":\"${cur_w:-0}\",\"ts\":\"$(date +%s)\"}" > "$STATE"
        chmod 600 "$STATE" 2>/dev/null
        # poll 秒数(下限 1)
        if [ "$poll" -lt 1000 ] 2>/dev/null; then sec=1
        else sec=$(( poll / 1000 )); fi
        [ "$sec" -lt 1 ] 2>/dev/null && sec=1
        sleep "$sec"
    done
}

start_daemon() {
    local pid
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "daemon already running (pid $pid)"; return 0
        fi
        rm -f "$PIDFILE"
    fi
    # 以 nohup 方式脱离启动; 显式用 sh 解释, 兼容本地与 KernelSU 环境
    # shellcheck disable=SC2086
    ( exec sh "$MODDIR/engine.sh" daemon </dev/null >>"$LOG" 2>&1 ) &
    pid=$!
    echo "$pid" > "$PIDFILE"
    chmod 600 "$PIDFILE" 2>/dev/null
    echo "daemon started (pid $pid)"
}

stop_daemon() {
    local pid
    [ -f "$PIDFILE" ] || { echo "no daemon pidfile"; return 0; }
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    # 状态复位, 避免残留 override
    [ -f "$STATE" ] && sed -i 's/"override":"[0-9]*"/"override":"0"/;s/"screen":"[0-9]*"/"screen":"0"/' "$STATE" 2>/dev/null
    echo "daemon stopped"
}

# daemon 是否存活: 0/1
daemon_alive() {
    local pid
    [ -f "$PIDFILE" ] || { echo 0; return 0; }
    pid=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo 1; return 0; }
    echo 0
}

# ---------------- 状态 JSON ----------------
get_status() {
    local profile temp en limit recover pct little mid big override alive applied
    local screen screen_auto
    profile=$(get_conf profile balanced)
    screen_auto=$(get_conf screen_auto 1)
    alive=$(daemon_alive)
    override="0"; screen="0"; applied="$profile"
    if [ "$alive" = "1" ] && [ -f "$STATE" ]; then
        # daemon 运行中: 优先用其缓存的温度/override/screen/applied
        temp=$(grep -o '"temperature":"[0-9]*"' "$STATE" | head -n1 | cut -d'"' -f4)
        override=$(grep -o '"override":"[0-9]*"' "$STATE" | head -n1 | cut -d'"' -f4)
        screen=$(grep -o '"screen":"[0-9]*"' "$STATE" | head -n1 | cut -d'"' -f4)
        applied=$(grep -o '"applied":"[^"]*"' "$STATE" | head -n1 | cut -d'"' -f4)
    fi
    [ -z "$temp" ] && temp=$(read_temp_raw)
    [ -z "$override" ] && override="0"
    [ -z "$screen" ] && screen="0"
    [ -z "$applied" ] && applied="$profile"
    en=$(get_conf thermal_enabled 1)
    limit=$(get_conf thermal_limit 40)
    recover=$(get_conf thermal_recover 37)
    # 报告实际生效档位的各层比例
    pct=$(profile_pct "$applied" 0); little=$pct
    pct=$(profile_pct "$applied" 1); mid=$pct
    pct=$(profile_pct "$applied" 2); big=$pct
    # 充电状态
    local charge_limit charge_current charge_voltage charge_auto charge_target_w charge_power_w
    charge_limit=$(get_conf charge_limit 1)
    charge_current=$(get_conf charge_current 3000000)
    charge_voltage=$(get_conf charge_voltage 4400000)
    charge_auto=$(get_conf charge_auto 0)
    charge_target_w=$(get_conf charge_target_w 90)
    charge_power_w=$(get_conf charge_power_w "")
    # 尝试读取实际充电参数
    local actual_current actual_voltage
    [ -r "$SYS/class/power_supply/battery/current_max" ] && \
        actual_current=$(cat "$SYS/class/power_supply/battery/current_max" 2>/dev/null)
    [ -r "$SYS/class/power_supply/battery/voltage_max" ] && \
        actual_voltage=$(cat "$SYS/class/power_supply/battery/voltage_max" 2>/dev/null)
    [ -z "$actual_current" ] && actual_current="$charge_current"
    [ -z "$actual_voltage" ] && actual_voltage="$charge_voltage"
    # 充电在线状态(仅诊断时读取)
    local charging
    charging=$(charge_online)
    echo "{\"profile\":\"$profile\",\"applied\":\"$applied\",\"override\":\"$override\",\"screen\":\"$screen\",\"screen_auto\":\"$screen_auto\",\"temperature\":\"$temp\",\"thermal_enabled\":\"$en\",\"thermal_limit\":\"$limit\",\"thermal_recover\":\"$recover\",\"little_pct\":\"$little\",\"mid_pct\":\"$mid\",\"big_pct\":\"$big\",\"daemon\":\"$alive\",\"charge_limit\":\"$charge_limit\",\"charge_auto\":\"$charge_auto\",\"charge_target_w\":\"$charge_target_w\",\"charge_power_w\":\"$charge_power_w\",\"charging\":\"$charging\",\"charge_current\":\"$actual_current\",\"charge_voltage\":\"$actual_voltage\"}"
}

# ---------------- 入口 ----------------
CMD="${1:-get}"

case "$CMD" in
    cpuinfo)
        # 输出 CPU 信息(供调试)
        echo "=== /proc/cpuinfo ==="
        grep -E "^processor|^Hardware|^CPU part|^CPU architecture|^Features" /proc/cpuinfo 2>/dev/null | head -20
        echo ""
        echo "=== cpufreq 层级 ==="
        for d in $SYS/devices/system/cpu/cpu[0-9]*/cpufreq; do
            [ -e "$d/cpuinfo_max_freq" ] || continue
            cpu=${d##*/cpu}
            maxf=$(cat "$d/cpuinfo_max_freq" 2>/dev/null)
            cur=$(cat "$d/scaling_cur_freq" 2>/dev/null)
            avail=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | wc -l)
            echo "  $cpu: max=${maxf}Hz cur=${cur}Hz avail=${avail}档"
        done
        echo ""
        echo "=== 温度节点 ==="
        for f in $SYS/class/thermal/thermal_zone*/type; do
            [ -r "$f" ] || continue
            z=$(dirname "$f" | sed "s|.*/thermal_zone||")
            t=$(cat "$f" 2>/dev/null | tr -d '\0')
            tmp=$(cat "${f%/type}/temp" 2>/dev/null)
            echo "  zone${z}: $t = ${tmp} (raw)"
        done
        [ -r "$SYS/class/power_supply/battery/temp" ] && \
            echo "  battery/temp: $(cat $SYS/class/power_supply/battery/temp 2>/dev/null)"
        ;;
    temp_debug)
        # 温度调试: 显示所有读取的温度节点和转换结果
        echo "=== 原始温度读数 ==="
        for f in \
            $SYS/class/power_supply/battery/temp \
            $SYS/class/thermal/thermal_zone*/temp; do
            [ -r "$f" ] || continue
            v=$(cat "$f" 2>/dev/null)
            case "$v" in
                ''|*[!0-9]*) continue ;;
            esac
            # 与 read_temp_raw 相同的逻辑: <1000 视为 0.1°C, >=1000 视为 0.001°C
            if [ "$v" -lt 100 ]; then continue
            elif [ "$v" -ge 1000 ]; then t=$((v / 100))
            else t=$v; fi
            # 校验范围: 手机正常温度 10°C 到 60°C
            valid="OK"
            [ "$t" -lt 100 ] && valid="TOO_LOW"
            [ "$t" -gt 600 ] && valid="TOO_HIGH"
            deg=$((t / 10))
            frac=$((t % 10))
            [ "$frac" -lt 0 ] && frac=$(( -frac ))
            echo "  $f: raw=$v -> ${deg}.${frac}°C [$valid]"
        done
        echo ""
        echo "=== 最终温度 ==="
        result=$(read_temp_raw)
        deg=$((result / 10))
        frac=$((result % 10))
        echo "读取结果: ${result} (0.1°C单位) = ${deg}.${frac}°C"
        ;;

    init)
        init
        ;;
    apply)
        P="${2:-}"
        if [ -z "$P" ]; then
            echo "usage: engine.sh apply <profile>"; exit 1
        fi
        case "$P" in balanced|powersave|thermal|performance) ;; *)
            echo "invalid profile: $P"; exit 1 ;; esac
        init
        apply_profile "$P"
        set_conf profile "$P"
        # 应用成功后同步状态文件
        get_status > "$STATE"; chmod 600 "$STATE" 2>/dev/null
        ;;
    boot)
        init
        boot_apply=$(get_conf boot_apply 1)
        if [ "$boot_apply" = "1" ]; then
            profile=$(get_conf profile balanced)
            apply_profile "$profile" >/dev/null 2>&1
            echo "boot: applied $profile"
        fi
        # 温控/待机/充电任一开启则拉起守护
        if [ "$(daemon_needed)" = "1" ]; then
            start_daemon
        fi
        ;;
    daemon)
        init
        daemon_loop
        ;;
    start)
        init; start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    charge_status)
        # 充电状态诊断
        echo "=== 充电控制路径探测 ==="
        detect_charge_paths | tr ' ' '\n' | grep -v '^$' | while read p; do
            echo "  $p: $(cat "$p" 2>/dev/null)"
        done
        echo ""
        echo "=== 当前充电参数 ==="
        get_charge_status
        echo ""
        echo "=== 配置 ==="
        cat "$CONF" 2>/dev/null
        ;;
    charge_fast)
        # 快速充电模式: 开启插电自动调节
        # 用法: charge_fast [目标功率W]  (默认 90, 范围 75~90)
        # 插电后按电池温度自动在 75W~目标W 之间调节, 最低保持 75W
        init
        target_w="${2:-$(get_conf charge_target_w 90)}"
        case "$target_w" in ''|*[!0-9]*)
            echo "invalid target watt"; exit 1 ;; esac
        if [ "$target_w" -lt 75 ] 2>/dev/null || [ "$target_w" -gt 90 ] 2>/dev/null; then
            echo "target watt must be 75~90"; exit 1
        fi
        set_conf charge_target_w "$target_w"
        set_conf charge_auto 1
        update_daemon
        apply_charge_auto_once
        echo "fast charge enabled: target=${target_w}W (插电自动 75~${target_w}W 按温度调节)"
        ;;
    charge_normal)
        # 正常充电模式: 关闭自动调节并恢复默认电流电压
        init
        norm_current="${2:-2000000}"    # 2A = 2000000uA
        norm_voltage="${3:-4200000}"    # 4.2V = 4200000uV
        set_charge_current "$norm_current"
        set_charge_voltage "$norm_voltage"
        toggle_charge_limit 1
        set_conf charge_current "$norm_current"
        set_conf charge_voltage "$norm_voltage"
        set_conf charge_auto 0
        set_conf charge_power_w ""
        update_daemon
        echo "normal charge restored: ${norm_current}uA / ${norm_voltage}uV (自动调节已关闭)"
        ;;
    get)
        init
        get_status
        ;;
    set)
        K="$2"; V="$3"
        [ -n "$K" ] || { echo "usage: engine.sh set <key> <value>"; exit 1; }
        init
        case "$K" in
            thermal_enabled)
                case "$V" in 0|1) set_conf "$K" "$V" ;;
                    *) echo "invalid value(0/1)"; exit 1 ;; esac
                update_daemon
                ;;
            profile)
                case "$V" in balanced|powersave|thermal|performance)
                    apply_profile "$V"; set_conf "$K" "$V" ;;
                    *) echo "invalid profile"; exit 1 ;; esac
                ;;
            thermal_limit|thermal_recover|poll_ms|boot_apply)
                case "$V" in ''|*[!0-9]*)
                    echo "invalid value, need number"; exit 1 ;; esac
                set_conf "$K" "$V"
                ;;
            screen_auto)
                case "$V" in 0|1) set_conf "$K" "$V" ;;
                    *) echo "invalid value(0/1)"; exit 1 ;; esac
                update_daemon
                ;;
            charge_auto)
                case "$V" in 0|1) set_conf "$K" "$V" ;;
                    *) echo "invalid value(0/1)"; exit 1 ;; esac
                if [ "$V" = "1" ]; then
                    update_daemon
                    apply_charge_auto_once
                else
                    update_daemon
                fi
                ;;
            charge_target_w)
                case "$V" in ''|*[!0-9]*)
                    echo "invalid value, need number (W 75~90)"; exit 1 ;; esac
                if [ "$V" -lt 75 ] 2>/dev/null || [ "$V" -gt 90 ] 2>/dev/null; then
                    echo "target watt must be 75~90"; exit 1
                fi
                set_conf "$K" "$V"
                if [ "$(get_conf charge_auto 0)" = "1" ]; then
                    apply_charge_auto_once
                fi
                ;;
            charge_limit)
                case "$V" in 0|1)
                    set_conf "$K" "$V"
                    [ "$V" = "1" ] && toggle_charge_limit 1 || toggle_charge_limit 0
                    ;;
                *) echo "invalid value(0/1)"; exit 1 ;; esac
                ;;
            charge_current|charge_voltage)
                case "$V" in ''|*[!0-9]*)
                    echo "invalid value, need number (microamps/microvolts)"; exit 1 ;; esac
                set_conf "$K" "$V"
                [ "$K" = "charge_current" ] && set_charge_current "$V"
                [ "$K" = "charge_voltage" ] && set_charge_voltage "$V"
                ;;
            *)
                echo "unknown key: $K"; exit 1 ;;
        esac
        get_status > "$STATE"; chmod 600 "$STATE" 2>/dev/null
        echo "set $K=$V"
        ;;
    *)
        echo "unknown cmd: $CMD"; exit 1 ;;
esac
