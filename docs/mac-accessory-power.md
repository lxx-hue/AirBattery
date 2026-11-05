# Mac 电量和鼠标充电通知

这一版把两件事接上了。都只用公开注册接口。没有 `com.apple.system.accpowersources.*`，没有 `IOPSCopyPowerSourcesByType`，也没有把实测到的非标准消息号写成含义。

Linux 上没有 IOKit，这里没有编译，也不能称编译通过。安装仍由 Mac 上的构建完成。

## 实测依据

本机诊断看到 `AppleDeviceManagementHIDEventService` 上的 Magic Mouse：基线电量 80%，`BatteryStatusFlags` 为 4。随后 4 次 `kIOGeneralInterest`，`messageType` 都是 `0x62747374`（公开头里没有这个名字），flags 依次是 5、3、5、4。没有 `kIOMessageServicePropertyChange`，也没有服务出现或消失。程序 120 秒后自己退出。

这说明这只鼠标在充电变化时，公开的 general interest 会回调，但消息号不是公开标准值。程序不比较这个数字。任何鼠标服务上的 interest 都只当作“去重读”的提示，然后走原来的 `BatteryPercent` / `BatteryStatusFlags` 读取。`4` 仍按原逻辑改记成 `0`。0.4 秒内的连续回调合成一次读取，所以 5 紧接着 3、以及 5 紧接着 4 这种成簇变化，会落到簇结束后的那个值。两次簇如果隔开数秒，会各自写一次。数值和上次已经写入的电量、充电标记相同，就不写设备、也不刷新小组件。

原来的 Magic 设备扫描还在，频率没有提高。鼠标服务消失后会卸掉对应的 interest；再次出现时按设备名更新同一行，不另建一行。键盘和触控板即使落在 `AppleDeviceManagementHIDEventService` 里，也不登记 interest。

## Mac 自身电量

状态栏 `mainBatteryView` 不再调用 `getPowerState()`。`mainTimer` 仍是每秒一次，只把内存里的 `InternalBattery.status` 抄到图标上，并维持原来的宽度调整。弹出层的每秒刷新也只读这份内存。

IOKit 读取改到通知之后：

| 来源 | 覆盖 | 本程序 |
| --- | --- | --- |
| `IOPSNotificationCreateRunLoopSource` | 公开头写明：电量百分比或剩余时间变化时都会投递，充电、放电过程中会比较频繁；对应的 `kIOPSNotifyTimeRemaining` 同时包含 AC、电池、UPS 切换 | 使用。回调后先等 0.4 秒，并且两次真正读取至少间隔 2 秒，然后调用原来的 `getPowerState()` |
| `IOPSCreateLimitedPowerNotification` | 只在 AC 与电池/UPS 之间切换时投递，百分比变化不投递 | 不使用。只用它会漏掉电量 |
| `kIOPSNotifyLowBattery` | 公开的低电量警告（大约还能用 20 分钟 / 10 分钟） | 不单独 `notify_register`。百分比和剩余时间通知已经会把这种变化带出来 |
| `NSProcessInfoPowerStateDidChange` | macOS 12 起的低电量模式开关 | 使用。读数仍是 `ProcessInfo.isLowPowerModeEnabled` |
| 启动时已有的 `getPowerState()` | 一次基线 | 保留。静态初值、`applicationWillFinishLaunching`、创建状态栏图标各一次 |
| 显示器唤醒 | 睡眠期间可能丢掉通知 | 唤醒时再读一次 Mac 电量，并重读已经登记的鼠标。不扫描手机 |

百分比、充电、充满、AC、低电量模式或有无电池发生变化时，才写内存并排队刷新小组件。只是剩余时间字符串变了（菜单里的 `timeLeft`）时，更新内存，不因此刷新小组件。

小组件原来的 `widgetViewTimer`（`60 * updateInterval` 秒）不动。状态变化引起的额外 `reloadAllTimelines` 至少间隔 15 秒，同一波变化合成一次，并且 `widgetInterval == -1` 时仍然不刷新。这次刷新只写已经在内存里的 `data.json`，不调用 iPhone / iPad / Watch 查询，也不做 BLE 扫描。

监听在 `applicationWillFinishLaunching` 启动，在 `applicationWillTerminate` 卸下运行循环源、interest、iterator 和通知端口。

## 没有改的定制

bundle id `com.lihaoyun6.AirBattery`、关闭 updater、去掉设置里的更新区、PrivateWidgetKit 玻璃背景、K580、Wi-Fi 充电标记、`scripts/build.sh` 的版本号和 deployment 12.0、`install-adhoc.sh` 的小组件 entitlements，都还在。

## Mac 上的编译和核对

在仓库根目录：

```bash
bash scripts/build.sh
```

构建脚本会把 deployment 设为 12.0 并递增 `CFBundleVersion`。不要把 Linux 上的静态检查说成编译通过。

装上之后可以看这几件事：

1. 菜单栏电量仍会随充电或放电变化。控制台出现 `Mac power ...` 只在读数真正变化时，而不是每秒两行。
2. 插拔妙控鼠标充电线后，大约半秒内出现一行 `Mouse power ...`。短时间内的 flags 5/3/4 不应连打多行相同结果。
3. 断开再连上鼠标，设备列表里仍是原来的名字，不多出一行。
4. iPhone、iPad、Watch 的刷新间隔和以前一样。插拔鼠标或 Mac 电源不该触发 `idevice` 或 BLE 扫描。
5. 小组件周期仍是原来的 60 秒档。电量或充电标记变化时可以额外刷新一次，但 15 秒内不会连刷。
6. 退出后进程结束，不残留监听进程。
