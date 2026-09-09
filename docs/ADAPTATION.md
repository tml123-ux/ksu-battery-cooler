# vivo X300pro (V2502A) 适配说明

## 设备信息

- **型号**: vivo X300pro (V2502A)
- **处理器**: 天玑9500 (MediaTek Dimensity 9500)
- **内核**: 6.12.58-android16-6-ga092cc003
- **CPU 架构**: 1+3+4 配置
  - 小核 (4x): 2.0GHz
  - 中核 (3x): 2.4GHz
  - 大核 (1x): 2.8GHz

## 已适配内容

### 温控阈值调整
- **触发温度**: 40°C（原默认 43°C）
- **恢复温度**: 37°C（原默认 40°C）
- **滞后**: 3°C 防止频繁切换

### 温度路径探测
- 优先读取 `/sys/class/power_supply/battery/temp`
- 其次读取 `/sys/class/thermal/thermal_zone*/temp`
- 自动识别 1°C / 0.1°C / 0.001°C 单位

### CPU 架构支持
- 自动识别小/中/大核层级
- 根据 `cpuinfo_max_freq` 排序分配比例
- vivo X300pro 预计为 Octa-core (4×小核 + 4×大核) 配置

## 安装步骤

1. 将 `battery-cooler-v1.0.0.zip` 推送到手机
2. KernelSU 管理器 → 模块 → 从本地安装
3. 重启设备
4. 在 KernelSU 管理器打开 WebUI 确认配置

## 设备诊断

如温控不生效，请运行诊断脚本：

```sh
# 在终端执行（需 root）
su -c "sh /data/adb/modules/battery-cooler/diagnose.sh"
```

或手动收集信息：

```sh
# CPU 架构
cat /proc/cpuinfo | grep -E "^processor|^Hardware"

# 温控节点
ls /sys/class/thermal/thermal_zone*/type | xargs -I{} sh -c 'echo -n "{}: "; cat {}'

# 当前状态
cat /data/adb/battery-cooler/state
```

## 档位说明

| 档位 | 小核 | 大核 | 适用场景 |
|------|------|------|----------|
| 均衡 | 100% | 100% | 日常使用 |
| 超级省电 | 80% | 55% | 续航优先 |
| 发烫限制 | 60% | 40% | 过热自动触发 |
| 性能 | 100% | 100% | 游戏/高负载 |

## 注意事项

- 不同内核版本的 cpufreq 节点权限可能不同
- 无写权限的核心会自动跳过并记录日志
- 长期压频可能影响多任务流畅度
- 安装后首次启动需等待约 5 秒让守护进程初始化

## 卸载

在 KernelSU 管理器中禁用模块并重启，或手动删除：

```sh
rm -rf /data/adb/modules/battery-cooler
rm -rf /data/adb/battery-cooler  # 数据目录
```
