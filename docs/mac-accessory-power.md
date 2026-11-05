# 配件电源监听已撤回

上一轮把 `notify_register_dispatch` 订到 `com.apple.system.accpowersources.*`，并用 `dlsym` 调用 `IOPSCopyPowerSourcesByType`。`notify(3)` 本身是公开接口，那三条名字和 `IOPSCopyPowerSourcesByType` 写在 `IOPowerSourcesPrivate.h`，头文件写明是 publicly unsupported。公开的 `notify_register_dispatch` 不会把私有通知名变成公开 API。这些调用已经从源码删掉。PrivateWidgetKit、bundle id、禁用 updater、K580、Wi-Fi 充电标记、`scripts/build.sh` 和 `install-adhoc.sh` 仍是已安装快照里的内容，没有撤掉。

没有安装，也没有在 Mac 上跑过。

## 公开电源通知覆盖什么

依据 apple-oss-distributions `IOKitUser` `ps.subproj/IOPowerSources.c` 和公开头 `IOPowerSources.h`：

| 公开 API | 注册的名字 | 覆盖 |
| --- | --- | --- |
| `IOPSNotificationCreateRunLoopSource` | `com.apple.system.powersources.timeremaining` | Mac 主电池 / UPS 的剩余时间，以及 AC、电池、UPS 切换 |
| `IOPSCreateLimitedPowerNotification` | `com.apple.system.powersources.source` | 当前供电从 AC 切到电池或 UPS |
| `kIOPSNotifyAttach` | `com.apple.system.powersources.attach` | 内置电池出现，或 UPS 插拔 |
| `kIOPSNotifyLowBattery` | `com.apple.system.powersources.lowbattery` | 系统低电量警告 |
| `kIOPSNotifyAnyPowerSource` | `com.apple.system.powersources` | IOPowerSource 属性。`pmset` 的 `pslog` 与 `accpslog` 把它和配件通道分开注册 |
| `IOPSCopyPowerSourcesInfo` | 内部调用 internal+UPS | 只返回内置电池和 UPS |

私有头里的 `com.apple.system.accpowersources.*` 和 `IOPSCopyPowerSourcesByType` 才对应 `pmset accps`。它们不是这次要接的公开接口，源码里不再出现。

## 公开 HID / IOKit 能不能在电量属性变化时通知

妙控鼠标的电量在 IORegistry 的 `AppleDeviceManagementHIDEventService` 上，属性名是 `BatteryPercent` 和 `BatteryStatusFlags`。发布者是 `com.apple.driver.AppleTopCaseHIDEventDriver`。整个公开的 IOHIDFamily 树里没有这两个属性名。

已经核对过的公开机制：

1. `IOServiceAddMatchingNotification`（`kIOFirstMatchNotification`、`kIOTerminatedNotification` 等）在服务出现或消失时调用。服务一直注册着、只改属性时，匹配通知不发生。鼠标连上时本应用已有 `IOBluetoothDevice.register(forConnectNotifications:)`。
2. `IOServiceAddInterestNotification` 的 `kIOGeneralInterest` 是公开的。xnu `IOService::messageClients` 只把消息发给 general interest。也就是说，interest 回调只有在该服务实际调用 `message` / `messageClients` 时才会进。
3. xnu 的 `IORegistryEntry::setProperty` 只改属性表，不调用 `messageClients`。单靠属性被写上，interest 不会响。
4. 公开的 `IOHIDDevice::setProperty`（IOHIDFamily `IOHIDDevice.cpp`）只在键属于 `kIOHIDDeviceMessagePropertyUpdateKeys` 时调用 `messageClients(kIOMessageServicePropertyChange)`。Apple 的 `HIDDevice.setPropertyChangeHandler` 也写明只接受这个列表，并且只处理 `kIOMessageServicePropertyChange`。`BatteryPercent` 不在 IOHIDFamily 源码里，不能把它算进这个列表。
5. 公开的 `IOHIDEventService::message` 只把 `kIOMessageServiceIsRequestingClose` 转给 `messageClients`。基类不会在任意 `setProperty` 时发属性变化消息。
6. `powerd` 对 `IOPMPowerSource` 注册 general interest，并只处理 `kIOPMMessageBatteryStatusHasChanged`。那是 Mac 自己的电源对象。妙控鼠标的类是 `AppleDeviceManagementHIDEventService`，不是 `IOPMPowerSource`。
7. registry 里能看到 `"IOGeneralInterest" = "IOCommand is not serializable"`。这表示对象上有 interest 命令槽，不表示 `BatteryPercent` 写入时会投递消息。`"BatteryStatusNotificationType" = "BatteryStatusChanged"` 是驱动放在属性里的字符串，公开头里没有对应的 notify 名，也没有找到发布这段字符串的开源代码。

`AppleDeviceManagementHIDEventDriver` 不在已公开的 IOHIDFamily 里。它的子类有可能自己调用 `messageClients`，这一点没有源码或实测可以证明。按“必须证明属性变化实际会通知”的要求，不能接上 interest 然后当作已经能跟着 `BatteryPercent` 更新。因此新增监听全部撤回，继续用基线里的 HID 轮询。

未解决：闭源的 `AppleTopCaseHIDEventDriver` 在改 `BatteryPercent` / `BatteryStatusFlags` 时是否调用 `messageClients`。这需要在 Mac 上对具体服务注册 `kIOGeneralInterest`，改电量后看回调里的 `messageType` 是不是 `kIOMessageServicePropertyChange`，并同时读到新的属性值。这次没有做这个实验，所以没有实现。

## Mac 自身电量：每秒读取何时发生

读数函数是 `Supports.swift` 的 `getPowerState()`，里面用 `InternalFinder.getInternalBattery()`：

- 打开 `AppleSmartBattery`
- 容量和充电来自该服务的 registry 属性
- 剩余时间来自公开 `IOPSCopyPowerSourcesInfo`（internal+UPS）
- `machineType` 不含 `book` 时直接返回无电池，不再查 IOKit

重复调用只有 `BatteryView.swift` 的 `mainBatteryView`：

```swift
.onReceive(mainTimer) { t in
    if item.hasBattery {
        InternalBattery.status = getPowerState()
        ...
        InternalBattery.status = getPowerState()
    }
}
```

`mainTimer` 在 `Supports.swift`：`Timer.publish(every: 1, on: .main, in: .common).autoconnect()`。Combine 的 autoconnect 在订阅数从 0 变 1 时启动，回到 0 时取消。SwiftUI 的 `onReceive` 跟这个视图的出现和消失走。

调用条件，以源码为准：

- `item` 的初值是创建视图时的 `InternalBattery.status`。`hasBattery == false`（台式 Mac，或 `machineType` 不含 `book`）时，这个每秒回调不再调用 `getPowerState`。
- `hasBattery == true` 时，非调试路径每个 tick 调用两次 `getPowerState`（第 155 行和第 161 行）。`intBattOnStatusBar == false` 只改图标宽度，不停止这次读取。
- 这个视图在 `applicationWillFinishLaunching` 里做成状态栏按钮的 `NSHostingView`，加到按钮上之后才设置 `statusBarItem.isVisible`。`showOn` 为 `dock` 或 `none` 时状态项被设为不可见，但视图对象在那之前已经创建。
- `setStatusBar` 会拆掉按钮上的子视图并新建一个 `mainBatteryView`，订阅跟着换。
- 菜单弹出层 `ContentView` 也订阅了 `mainTimer`，但只在 `!fromDock && menuPopover.isShown` 时刷新设备列表，读的是已经写好的 `InternalBattery.status`，不调用 `getPowerState`。关掉弹出层不会拆掉状态栏上的 `mainBatteryView`。
- Dock 磁贴用的 `MultiBatteryView` 不订阅 `mainTimer`，也不调用 `getPowerState`。它用 5 秒的 `dockTimer` 转设备列表。
- 另外三次单次读取与视图是否显示无关：`InternalBattery.status` 的静态初值、`applicationWillFinishLaunching`、创建状态栏图标时。

没有在 Mac 上观察过隐藏状态栏之后，`NSHostingView` 是否仍算出现、autoconnect 是否还在跑。源码只能确定：每秒的 IOKit 读取写在状态栏这个视图里；弹出层的显示和隐藏不直接开关这次读取；Dock 磁贴自己不读。状态项被隐藏后订阅是否还在，仍是未测点。

iPhone、iPad、Watch 的轮询间隔没有改。
