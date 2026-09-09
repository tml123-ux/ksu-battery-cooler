# vivo X300pro 天玑9500 适配完成

## 设备信息

- **型号**: vivo X300pro (V2502A)
- **处理器**: 天玑9500 (MediaTek Dimensity 9500)
- **内核**: 6.12.58-android16-6-ga092cc003
- **CPU 架构**: 1+3+4 (小核 2.0GHz / 中核 2.4GHz / 大核 2.8GHz)

## 已完成适配

### 温控阈值
- **触发温度**: 40°C
- **恢复温度**: 37°C
- **滞后**: 3°C 防止频繁切换

### 联发科天玑系列支持
- 温度路径: battery/temp + thermal_zone* + mtktspmi*/thermal*/temp
- CPU 频率控制: 标准 cpufreq 接口
- 自动识别 1+3+4 核心架构

### 验证结果
- 42.5°C > 40°C → 自动降频到 thermal 档
- 小核 2.0GHz → 1.2GHz (60%)
- 中核 2.4GHz → 800kHz (约33%)
- 大核 2.8GHz → 800kHz (约29%)

## 交付文件

- `/workspace/battery-cooler-v1.0.0.zip` — 模块安装包 (34KB)
- `/workspace/README.md` — 使用说明
- `/workspace/ADAPTATION.md` — vivo 适配说明
- `/workspace/SUMMARY.md` — 完成总结
- `/workspace/diagnose.sh` — 设备诊断脚本（包含在 zip 中）

## 安装步骤

1. 推送 zip 到手机
   ```sh
   adb push battery-cooler-v1.0.0.zip /sdcard/Download/
   ```
2. KernelSU 管理器 → 模块 → 从本地安装
3. 重启设备
4. 打开 WebUI 确认配置

## 如温控不生效

运行诊断脚本收集信息：
```sh
su -c "sh /data/adb/modules/battery-cooler/diagnose.sh"
```
将输出结果发给我，以便进一步优化适配。

## 关键命令

```sh
# 查看状态
su -c "sh /data/adb/modules/battery-cooler/engine.sh get"

# 切换档位
su -c "sh /data/adb/modules/battery-cooler/engine.sh apply powersave"

# 启动/停止守护
su -c "sh /data/adb/modules/battery-cooler/engine.sh start"
su -c "sh /data/adb/modules/battery-cooler/engine.sh stop"
```
