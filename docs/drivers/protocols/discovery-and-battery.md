# 设备识别与蓝牙电量

这两部分在 macOS 和 Windows 上做法完全不同，移植时要重写；这里记下 MacPulse 的做法和对应的 Windows 思路。

## USB 键盘识别

macOS（`WiredKeyboardWatcher`，`Source/VIAKeyboard.swift`）：

- IOHIDManager 匹配 `PrimaryUsagePage = 1, PrimaryUsage = 6`，注册插入和拔出回调，放在设备队列上，不调用 `IOHIDManagerOpen`，不打开设备，因此不需要“输入监控”权限。
- 每个设备只读 `Transport`、`VendorID`、`ProductID`、`LocationID`、`Product`。
- 只保留 `Transport == "USB"`；排除 WLMOUSE（`0x36A7`）、罗技（`0x046D`）和名字含 receiver / dongle / mouse / 接收器 的设备（鼠标接收器也带键盘接口）。
- 一把键盘有好几个接口，按 `VID-PID-LocationID` 去重，ID 形如 `usb-1a86-fc16-00123000`。插拔后等 0.5 秒再统一刷新列表。

Windows 思路：`SetupDiGetClassDevs(GUID_DEVINTERFACE_HID)` 或 hidapi 的 `hid_enumerate(0, 0)`，按 `usage_page == 1 && usage == 6` 筛键盘；系统独占键盘 collection，但 VIA 用的 `0xFF60` collection 是单独的，可以直接打开。同型号多把键盘用设备路径或 `interface_number` + 父设备实例区分。

## 蓝牙外设电量

macOS（`PeripheralReader`，`Source/Peripherals.swift`）：遍历 IORegistry 里的 `AppleDeviceManagementHIDEventService`，读 `BatteryPercent`（0–100）和 `Product`。妙控键盘、妙控鼠标、妙控板以及部分第三方 BLE 外设会在这里报告电量。不需要任何权限，也不跟设备通信。

Windows 思路：BLE 外设走 GATT Battery Service（`0x180F`，特征 `0x2A19`），用 `Windows.Devices.Bluetooth.GenericAttributeProfile`；经典蓝牙 HID 设备通常拿不到电量，设置里的电量来自厂商驱动或 HFP。

## 本机实测设备

| 设备 | VID | PID | 连接 | 接口（Usage Page / Usage） |
|---|---|---|---|---|
| BUFF67v3r2 | `0xB710` | `0xB710` | USB | 1/6 键盘，1/2 鼠标，`0xFF60`/`0x61` VIA |
| BNK 16 | `0x1A86` | `0xFC16` | USB | 1/6 键盘，12/1 多媒体，`0xFF60`/`0x61` VIA |
| WLMOUSE MINI PRO 8K RECEIVER | `0x36A7` | `0xA868` | USB | 1/2 鼠标，12/1 多媒体，`0xFFFF`/`0` 命令通道 |

完整列表和报告描述符在 `devices/*/hid-interfaces.txt`、`hid-report-descriptors.txt`。
