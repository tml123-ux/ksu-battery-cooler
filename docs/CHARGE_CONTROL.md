# vivo X300pro 充电控制功能说明

## 重要提示：硬件限制

**模块的智能快充在 75W~90W 之间按电池温度自动调节，最低保底 75W。实际功率仍取决于充电器/线缆/接口与充电IC上限，软件无法突破硬件物理限制。**

可能的原因：
1. 充电器本身功率不足（可能不是原装或已损坏）
2. 充电线缆质量差或破损
3. USB-C 接口接触不良
4. 电池管理系统限制

## 已添加的充电控制功能

模块新增了充电控制实验性功能：

### WebUI 界面
- 智能快充开关（插电自动按温度调节）
- 目标功率滑杆（75~90W）
- 实时请求功率 / 充电器连接状态 / 电流电压显示
- 充电路径诊断

### 自动调节逻辑
- 电池温度 **≤ 36°C**：按目标功率请求（最高 90W）
- 电池温度 **升高**：请求功率线性下降
- 电池温度 **≥ 46°C**：降到最低并**保底 75W**，温度回落自动恢复目标

### 命令行
```sh
# 查看充电路径
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_status"

# 开启智能快充(默认目标 90W, 插电自动在 75~90W 间按温度调节)
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_fast"

# 指定目标功率 75~90W 例如 85W
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_fast 85"

# 调整目标功率
su -c "sh /data/adb/modules/battery-cooler/engine.sh set charge_target_w 82"

# 关闭智能快充, 恢复默认充电（2.0A / 4.2V）
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_normal"
```

### 尝试提升充电功率

虽然软件无法突破硬件限制，但可以尝试：

1. **检查充电器铭牌**
   ```sh
   # 查看支持的充电协议
   cat /sys/class/power_supply/battery/tech
   cat /sys/class/power_supply/battery/chemistry
   ```

2. **运行诊断脚本**
   ```sh
   su -c "sh /data/adb/modules/battery-cooler/diagnose.sh"
   ```

3. **观察自动调节效果**
   ```sh
   # 查看当前请求电流/电压与实际充电功率
   su -c "sh /data/adb/modules/battery-cooler/engine.sh get"
   cat /sys/class/power_supply/battery/current_now
   cat /sys/class/power_supply/battery/voltage_now
   ```

## 预期结果

- 插上支持快充的电源且温度较低：软件会按目标(最高 90W)请求，实际功率取决于硬件
- 电池温度升高：请求功率自动下降，最低保持 75W，温度回落自动恢复
- 如果硬件限制更低（如 35W）：软件提升无效，功率不变

## 下一步

请运行诊断脚本并将结果发给我，我可以：
1. 确认设备的充电路径
2. 尝试更激进的提升参数
3. 分析为何只能达到 35W
