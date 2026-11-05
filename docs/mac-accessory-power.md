# Mac 本地电源配件通知

本文说明这次改动相对已安装快照（`7ff2f78` 的 tracked 源码，分支上的基线提交）做了什么。Linux 上不能编译或运行 macOS 应用，下面没有秒级响应或耗电数据。

## 定制基线

工作区 `main` 是 fork 上的上游 `134e02f`。已安装版本的定制不在这条历史上，附件快照已整树提交为基线，之后才加配件监听。保留的内容包括：

- Bundle ID `com.lihaoyun6.AirBattery`（Helper / widget 前缀不变）
- Sparkle `startingUpdater: false`，设置里的更新区仍删除
- 8 格 widget 使用 `preferredBackgroundStyle(.blur)` 与透明 container background；`scripts/build.sh` 每次递增 `CFBundleVersion`，并传入 PrivateWidgetKit
- `scripts/install-adhoc.sh` 用 widget entitlements 重签，避免 sandbox 被剥掉
- `scripts/build.sh` 的 `MACOSX_DEPLOYMENT_TARGET=12.0`（工程文件里的 target 仍是快照中的 11.0，正式安装走该脚本）
- K580 等已连接 BLE 键盘：`readConnectedBatteryPeripherals()`，读 0x180F/2A19，不订阅 notify，间隔仍是扫描 `29 * updateInterval`、读取门闩 `60 * updateInterval`
- Wi-Fi 充电标记：`IDeviceBattery.chargeState` 与 USB 拔出清理
- iPhone/iPad 轮询与 Watch 的 `comptest` lockdown 读取

## Mac 自身电量（未改频率）

| 项 | 位置 |
| --- | --- |
| 入口 | `Supports.swift` `getPowerState()` |
| 触发 | `BatteryView.swift` 的 `mainBatteryView` 订阅 `mainTimer`。`mainTimer` 是 `Timer.publish(every: 1, ...)`，即菜单栏视图存在时每 1 秒读一次。启动时 `applicationWillFinishLaunching` 再读一次 |
| 机型 | `machineType` 不含 `book` 时直接返回无电池，不再查 IOKit |
| 读数 | `InternalFinder.getInternalBattery()` 打开 `AppleSmartBattery`，容量、充电、外接电源来自该服务的 registry 属性（`CurrentCapacity`、`MaxCapacity`、`IsCharging`、`FullyCharged`、`ExternalConnected` 等） |
| 剩余时间 | 公开 `IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList` / `IOPSGetPowerSourceDescription` 的 `kIOPSTimeToEmptyKey`、`kIOPSTimeToFullChargeKey`。公开 `IOPSCopyPowerSourcesInfo()` 在 IOKitUser 里固定请求 internal+UPS，不含配件 |
| 低电量模式 | macOS 12+ `ProcessInfo.processInfo.isLowPowerModeEnabled` |

这是 1 秒轮询，不是电源通知。本次没有把主电池通知接到配件更新上，也没有改这个 1 秒定时器。

## 公开 IOPS 通知实际覆盖什么

依据 apple-oss-distributions `IOKitUser` `ps.subproj/IOPowerSources.c` 与公开头 `IOPowerSources.h`（`pmset` 的 `pslog` / `accpslog` 与之对应）：

| API 或 notify 名 | 实现注册的名字 | 覆盖 |
| --- | --- | --- |
| `IOPSNotificationCreateRunLoopSource` | `com.apple.system.powersources.timeremaining` | Mac 主电池 / UPS 的剩余时间，以及 AC、电池、UPS 之间的电源切换。头文件写明会在主电池充放电时较频繁触发 |
| `IOPSCreateLimitedPowerNotification` | `com.apple.system.powersources.source` | 仅当前供电从无限（AC）切到有限（电池/UPS），不含电量百分比 |
| `kIOPSNotifyAttach` | `com.apple.system.powersources.attach` | 发现内置电池，或 UPS 插拔。头文件写明笔记本插拔 AC 不走这条 |
| `kIOPSNotifyLowBattery` | `com.apple.system.powersources.lowbattery` | 系统低电量警告 |
| `kIOPSNotifyAnyPowerSource` | `com.apple.system.powersources` | 任意 IOPowerSource 属性。`pmset` 把它和配件通道分开注册 |
| `kIOPSNotifyPercentChange`（私有头） | `com.apple.system.powersources.percent` | 主机电源百分比 / 供电切换，不是 HID 配件 |
| 公开 `IOPSCopyPowerSourcesInfo` | 调用 `kIOPSSourceInternalAndUPS` | 只返回内置电池和 UPS |

这些都不是妙控鼠标通知。本次没有订阅它们。

配件通道在 `IOPowerSourcesPrivate.h`，头文件自述为 publicly unsupported。`pmset accpslog` 在 `kApplyToAccessories` 时额外监听：

| notify 名 | 含义 |
| --- | --- |
| `com.apple.system.accpowersources.timeremaining` | 任一配件电源的容量或剩余时间变化。`IOPSAccNotificationCreateRunLoopSource` 注册的就是它 |
| `com.apple.system.accpowersources.attach` | 配件电源注册或注销 |
| `com.apple.system.accpowersources.source` | 配件在有限/无限电源之间切换（插电），不含百分比 |

读取对应快照的是私有 `IOPSCopyPowerSourcesByType(kIOPSSourceForAccessories)`，枚举值为 4。公开的 Copy 函数不会返回这组数据。私有键 `Accessory Category` 的取值包括 Mouse、Keyboard、Trackpad，也包括 Watch、Headphone、Pencil。Transport 可以是 Bluetooth、Bluetooth LE、USB。

Apple Watch 在本应用里仍由 iPhone 的 `comptest` 读出。私有分类里有 Watch，不代表 Mac 上的 IOPS 能代替 lockdown。事件路径遇到分类 Watch，或已有记录类型为 Watch / iPhone / iPad / iPod / Pencil / ApplePencil，直接跳过。

## 实现

`AccessoryPowerMonitor`（仅主 app target）：

1. 启动时用公开 `notify_register_dispatch` 订阅上面三条配件名字，回调在串行队列 `com.lihaoyun6.AirBattery.acc-power`。退出时 `notify_cancel`。三条都注册失败则只保留原有扫描。
2. 去抖：单次事件延迟 2 秒；连续通知（充电中剩余时间可能连发）最多 5 秒必定读一次。电量和充电标志都没变则不写 JSON、不 reload。
3. 先走现有 HID 读取（`AppleDeviceManagementHIDEventService`、`AppleBluetoothHIDKeyboard`、`BNBTrackpadDevice`、`BNBMouseDevice`），解析仍是 `BatteryPercent` / `BatteryStatusFlags`（4 记为未充电）。只在电量或充电标志变化时 `updateDevice`。周期扫描仍用默认参数，每次重写 `lastUpdate`。
4. 再用 `dlsym` 找 `IOPSCopyPowerSourcesByType`。符号不存在就跳过，启动不受影响。读到的记录里，registry 已经见过的 id/名字保持 HID 解析结果。其余只接受 Mouse / Keyboard / Trackpad；分类为空或 Unknown 时，仅当传输是 Bluetooth、Bluetooth LE 或 USB 且名字含 mouse/keyboard/trackpad。跳过 Internal、UPS、未 Present 的源。
5. 有变化才 `writeData()`。Widget reload 与钉住状态栏刷新在主线程，最少间隔 15 秒，避免把 60 秒的 `widgetViewTimer` 变成更密的周期定时器。
6. `readBTDevice == false` 时事件到达后直接返回。

没有新增 iPhone/iPad/Watch 查询，没有 `system_profiler`，没有 BLE 扫描，没有改 Wi-Fi 60 秒、widget 60 秒、BLE 读取门闩。

## 在 Mac 上验证

Linux 已跑 `scripts/check-accessory-power.sh`（源码约束 + 规则样例）。Mac 上还需要：

1. `scripts/build.sh` 能编过。重点看 `notify_register_dispatch` 的 `@_silgen_name` 签名，以及 `IOPSCopyPowerSourcesList` 的 `as Array` 写法是否与现有 `InternalBattery.swift` 一致。
2. `scripts/install-adhoc.sh` 安装后，Console 有 `listening for N accessory power notifications`。N 应为 3。若为 0，配件监听没挂上，原扫描仍在。
3. 妙控鼠标（以及键盘、触控板）电量变化后，菜单和 widget 在下一次成功 reload 时更新。不要把这次观察写成“已实测秒级”或“已实测更省电”。`pmset -g accpslog` 可对照是否出现 `accpowersources` 而不是只有主电池那组名字。
4. 只插拔电源适配器、或只让 Mac 自己电量跳 1%，鼠标行不应跟着改。这是确认没有把主电池通知当成配件通知。
5. iPhone/iPad 仍按原来的 Wi-Fi/USB 节奏更新；Watch 仍只在 `comptest` 成功时变化。配件事件期间不要出现额外的 `ideviceinfo` / `comptest`。
6. K580 仍约 60 秒读一次 2A19，而不是变为通知订阅。
7. 每个鼠标/键盘/触控板只出现一行。若 IOPS 的 Accessory Identifier 与 HID 的 DeviceAddress 格式不一致，可能出现重复行，需要再收紧匹配。
8. 设置里关掉 “Discover BT and BLE devices” 后，配件通知不应再写设备。
9. 退出应用后不再留下 `notify` 回调（重新打开只注册一次）。
