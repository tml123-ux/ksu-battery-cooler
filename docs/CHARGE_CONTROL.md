# vivo X300pro 充电控制功能说明

## 重要提示：硬件限制

**原装充电器实际只能输出 35W，这是物理限制，软件无法突破。**

可能的原因：
1. 充电器本身功率不足（可能不是原装或已损坏）
2. 充电线缆质量差或破损
3. USB-C 接口接触不良
4. 电池管理系统限制

## 已添加的充电控制功能

模块新增了充电控制实验性功能：

### WebUI 界面
- 快速充电开关
- 充电电流/电压显示
- 充电路径诊断

### 命令行
```sh
# 查看充电路径
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_status"

# 启用快速充电（4.5A / 4.4V，理论 ~75W）
su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_fast"

# 恢复默认充电（2.0A / 4.2V）
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

3. **手动测试不同电流值**
   ```sh
   # 尝试 3A
   su -c "sh /data/adb/modules/battery-cooler/engine.sh charge_fast 3000000"
   # 观察充电功率变化
   cat /sys/class/power_supply/battery/current_now
   cat /sys/class/power_supply/battery/voltage_now
   ```

## 预期结果

- 如果硬件支持 75W 充电：软件提升后功率会增加
- 如果硬件限制 35W：软件提升无效，功率不变

## 下一步

请运行诊断脚本并将结果发给我，我可以：
1. 确认设备的充电路径
2. 尝试更激进的提升参数
3. 分析为何只能达到 35W
