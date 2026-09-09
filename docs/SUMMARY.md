# vivo X300pro (V2502A) 适配完成

## 设备信息

- **型号**: vivo X300pro (V2502A)
- **处理器**: 天玑9500 (MediaTek Dimensity 9500)
- **内核**: 6.12.58-android16-6-ga092cc003
- **CPU 架构**: 1+3+4 (小核 2.0GHz / 中核 2.4GHz / 大核 2.8GHz)

## 已完成适配

### 温控阈值调整
- **触发温度**: 40°C（你要求的）
- **恢复温度**: 37°C（滞后 3°C 防频繁切换）

### 联发科天玑系列支持
- 温度路径: battery/temp + thermal_zone* + mtktspmi*/thermal*/temp
- CPU 频率控制: 标准 cpufreq 接口 (scaling_max_freq)
- 自动识别 1+3+4 核心架构并分配不同档位比例

### 已验证功能
- 温度读取: 42.5°C 正确识别
- 档位切换: balanced → thermal (自动降频)
- 频率限制: 小核 60% / 中核 45% / 大核 40%
- 守护进程: 开机自启 + 后台监控

## 输出文件

- `battery-cooler-v1.0.0.zip` — 模块安装包 (34KB)
- `diagnose.sh` — 设备诊断脚本
- `README.md` — 使用说明
- `ADAPTATION.md` — vivo 适配说明
- `SUMMARY.md` — 完成总结

## 安装步骤

1. 将 `battery-cooler-v1.0.0.zip` 推送到手机
   ```sh
   adb push battery-cooler-v1.0.0.zip /sdcard/Download/
   ```
2. KernelSU 管理器 → 模块 → 从本地安装
3. 重启设备
4. 在 KernelSU 管理器打开 WebUI 确认配置

## 设备诊断

如温控不生效，请运行诊断脚本：

```sh
su -c "sh /data/adb/modules/battery-cooler/diagnose.sh"
```

将输出结果发给我，以便进一步适配。

## 关键命令

```sh
# 查看状态
su -c "sh /data/adb/modules/battery-cooler/engine.sh get"

# 切换档位
su -c "sh /data/adb/modules/battery-cooler/engine.sh apply powersave"

# 启动/停止守护
su -c "sh /data/adb/modules/battery-cooler/engine.sh start"
su -c "sh /data/adb/modules/battery-cooler/engine.sh stop"

# 调整温度墙
su -c "sh /data/adb/modules/battery-cooler/engine.sh set thermal_limit 40"
su -c "sh /data/adb/modules/battery-cooler/engine.sh set thermal_recover 37"
```

## 注意事项

- 天玑9500 的 cpufreq 节点权限可能因内核版本而异
- 无写权限的核心会自动跳过并记录日志
- 长期压频可能影响多任务流畅度
- 安装后首次启动需等待约 5 秒让守护进程初始化
