# 省电与限制发烫 (battery-cooler)

KernelSU 模块，通过 sysfs 限制 CPU 最高频率，提供四档性能调度 + 过热自动降频。

## vivo X300pro (V2502A) 适配

- **处理器**: 天玑9500 (MediaTek Dimensity 9500)
- **内核版本**: 6.12.58-android16-6-ga092cc003
- **默认温控阈值**: 40°C 触发降频，37°C 恢复
- **CPU 架构**: 1+3+4 (小核 2.0GHz / 中核 2.4GHz / 大核 2.8GHz)
- **温度路径**: battery/temp + thermal_zone* + 联发科特定路径

## 功能

| 档位 | 小核 | 中核 | 大核 | 用途 |
|------|------|------|------|------|
| 🌿 均衡 balanced | 100% | 100% | 100% | 默认，日常推荐 |
| 🔋 超级省电 powersave | 80% | 65% | 55% | 续航优先 |
| 🧊 发烫限制 thermal | 60% | 45% | 40% | 主动压频降温 |
| 🚀 性能模式 performance | 100% | 100% | 100% | 满血释放 |

## 充电控制（实验性）

**注意**: 充电功率受硬件限制（充电器、线缆、接口），软件无法突破物理上限。

| 命令 | 功能 |
|------|------|
| `charge_fast` | 启用快速充电（4.5A / 4.4V，理论 ~75W）|
| `charge_normal` | 恢复默认充电（2.0A / 4.2V，理论 ~8.4W）|
| `charge_status` | 查看充电路径和参数 |

WebUI 中已添加充电控制卡片，可在界面中切换。

## 温控守护（自动降频）

开启后后台每 N 秒读取一次设备最高温度：

- 温度 **>= 温度墙**（默认 40°C）→ 临时压到 thermal 档，直到温度回落
- 温度 **<= 恢复温度**（默认 37°C）→ 自动恢复用户所选档位
- 用户在过热期间手动切换档位 → 以新档位为准重新评估

## 文件结构

```
battery-cooler/
├── module.prop        # 模块元数据
├── customize.sh       # 安装脚本(赋执行权限)
├── service.sh         # 开机应用档位 + 启动守护
├── action.sh          # 管理器"动作"按钮: 均衡/性能 快速切换
├── engine.sh          # 核心引擎(档位/温度/守护/配置)
└── webroot/
    ├── index.html     # WebUI 控制面板
    └── js/kernelsu.js # KernelSU bridge (经典脚本封装)
```

运行时数据存于 `/data/adb/battery-cooler/`（config.conf 配置、state 状态、monitor.log 日志、monitor.pid 守护 pid）。模块升级/卸载不影响配置。

## 安装

1. 将 `battery-cooler-*.zip` 推送到手机
2. KernelSU 管理器 → 模块 → 从本地安装，选择该 zip
3. 安装后在模块页打开 WebUI 进行配置

## WebUI 操作

- 点选档位卡片 → 立即切换并保存
- 「智能温控守护」开关 → 启用/停用自动降频
- 「触发温度」「恢复温度」滑杆 → 实时调整温度墙
- 「一键恢复」→ 切回均衡并停用温控

## 手动命令

```sh
# 查看 CPU 架构与温度节点(调试用)
su -c "sh /data/adb/modules/battery-cooler/engine.sh cpuinfo"

# 查看充电状态
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_status"

# 启用快速充电
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_fast"

# 恢复默认充电
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_normal"

# 应用档位
su -c "sh /data/adb/modules/battery-cooler/engine.sh apply powersave"
# 查看状态
su -c "sh /data/adb/modules/battery-cooler/engine.sh get"
# 启动/停止温控守护
su -c "sh /data/adb/modules/battery-cooler/engine.sh start"
su -c "sh /data/adb/modules/battery-cooler/engine.sh stop"
# 改温度墙(单位 °C)
su -c "sh /data/adb/modules/battery-cooler/engine.sh set thermal_limit 40"
su -c "sh /data/adb/modules/battery-cooler/engine.sh set thermal_recover 37"
```

## 原理与兼容性

- 对每个在线 CPU 核，依据其 `cpuinfo_max_freq` 所在层级（小/中/大核）套用档位比例，
  从 `scaling_available_frequencies` 中挑选最接近且不超过目标的频率写入 `scaling_max_freq`。
- 温度读取：多路径探测（battery/temp + thermal_zone* + 联发科特定路径），
  自动识别 0.1°C / 0.001°C 单位，非法值自动过滤。
- 找不到可写节点时自动跳过并记录日志，不会破坏系统文件（systemless）。
- 仅通过 sysfs 限频，不改调度器/内核，卸载后随模块移除（恢复需重启或手动 apply balanced）。

## 免责说明

- 不同内核的 cpufreq 节点权限与可用频率表不同，若某核无写权限会被跳过并计入日志。
- 长期压频可能影响大负载应用流畅度，请按实际发热情况选择档位与温度墙。
