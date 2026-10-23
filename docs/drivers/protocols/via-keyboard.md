# VIA 键盘协议（MacPulse 实现）

适用：BUFF67v3r2（VLstudio，VIA 协议 v11）和 Binepad BNK16 有线版（yukeboard 固件，VIA 协议 v12）。两把都在本机实测过读写。实现在 `Source/VIAKeyboard.swift`，型号表和键码表在 `Source/Keyboard.swift`。

## 设备与接口

| 键盘 | VID | PID | VIA 协议 | 矩阵 | 层 | 宏 | 宏缓冲区 | 旋钮 |
|---|---|---|---|---|---|---|---|---|
| BUFF67v3r2 | `0xB710` | `0xB710` | 11（`0x000B`） | 5 × 15 | 4 | 16 | 386 字节 | 无 |
| BNK 16 | `0x1A86` | `0xFC16` | 12（`0x000C`） | 5 × 5 | 10 | 18 | 1008 字节 | 3 |

VIA 通道是一个独立的 HID 接口：**Usage Page `0xFF60`，Usage `0x61`**。它和键盘接口不是同一个 collection，所以打开它不需要系统的键盘（输入监控）权限。

它的报告描述符是标准的 QMK raw HID（两把一样）：

```
06 60 FF  09 61  A1 01
  09 62  15 00 26 FF 00  95 20  75 08  81 02   ; Input  32 字节
  09 63  15 00 26 FF 00  95 20  75 08  91 02   ; Output 32 字节
C0
```

没有 Report ID。发送 32 字节输出报告，收到 32 字节输入报告。

- macOS：`IOHIDDeviceSetReport(kIOHIDReportTypeOutput, reportID 0, 32 字节)`，回复从输入报告回调里取。
- Windows（hidapi）：`hid_write` 要在最前面多放一个 `0x00`（Report ID），共 33 字节；`hid_read` 读 32 字节。用 `hid_enumerate` 按 `usage_page == 0xFF60 && usage == 0x61` 找接口。

回复的第 0 字节回显命令号。第 0 字节是 `0xFF` 表示固件不认识这条命令。MacPulse 每条命令最多等 0.4 秒，没回复重发两次。

## 用到的命令

只有下面这些命令会被发送。多字节数值都是**大端**。

| 命令 | 名称 | 请求 | 回复里的数据 |
|---|---|---|---|
| `0x01` | 协议版本 | `01` | `r[1..2]` 版本 |
| `0x11` | 层数 | `11` | `r[1]` |
| `0x12` | 读键位缓冲 | `12 offHi offLo size(≤28)` | `r[4..]` 键码，每个 2 字节 |
| `0x05` | 写单个键 | `05 layer row col kcHi kcLo` | 回显 |
| `0x14` | 读旋钮 | `14 layer index cw` | `r[4..5]` 键码；`cw` 0 = 逆时针，1 = 顺时针 |
| `0x15` | 写旋钮 | `15 layer index cw kcHi kcLo` | 回显 |
| `0x0C` | 宏数量 | `0C` | `r[1]` |
| `0x0D` | 宏缓冲区大小 | `0D` | `r[1..2]` |
| `0x0E` | 读宏缓冲 | `0E offHi offLo size(≤28)` | `r[4..]` |
| `0x0F` | 写宏缓冲 | `0F offHi offLo size data…` | 回显 |
| `0x08` | 读自定义值（灯光） | `08 channel valueId` | `r[1]=channel r[2]=valueId r[3..]=值` |
| `0x07` | 设自定义值（不保存） | `07 channel valueId 值…` | 回显 |
| `0x09` | 保存一个 channel | `09 channel` | 回显 |

键位缓冲按 `layer → row → col` 排列：第 `layer` 层 `(row, col)` 的偏移是 `(layer × rows × cols + row × cols + col) × 2`。

### 永远不发的命令

| 命令 | 原因 |
|---|---|
| `0x02` 读键盘信息（uptime 等） | **BNK16 收到后整个 VIA 通道卡死**，要等一会儿才恢复 |
| `0x06` 重置键位、`0x10` 重置宏 | 破坏性 |
| `0x0A` 清 EEPROM、`0x0B` 进刷机模式 | 破坏性 |
| BNK16 菜单 channel 3 的三个按钮（重启、恢复出厂、升级模式） | 破坏性 |

选键器也不提供 `QK_BOOT 0x7C00`、`QK_REBOOT 0x7C01`、`QK_CLEAR_EEPROM 0x7C03`，以及 BNK16 定义里的 Reset、Clean EEPROM、Update、usb mode、backup 这些自定义键（`data/keyboards.json` 里标了 `hiddenInPicker`）。

## 固件怪癖

- **BNK16 读键位不能跨层**：一次 `0x12` 读取如果跨过两层的分界，跨过去的部分会返回 0。例如从偏移 28 读 28 字节（第 0 层末尾加第 1 层开头），后半段全是 0；从第 1 层起点（偏移 50）读就正常。MacPulse 逐层读取，每层内部按 28 字节分块。
- **BNK16 不能发 `0x02`**，见上表。
- **BUFF67 的 VID/PID 和上游定义不同**：上游 QMK 和 Oh-My-Mechanical-Keyboard 发布的 buff67v3 是 `0xAA96 / 0xAA88`，这把 v3r2 是 `0xB710 / 0xB710`，要用 `sources/via-definitions/BUFF67v3r2.json`。键位布局两者相同（5 × 15，67 键）。

## 协议 v11 和 v12 的键码差异

基本键、修饰、层功能等在两个版本里一样（都是 QMK 0.19 以后的新键码）。不同的是这两段：

| | v11（BUFF67） | v12（BNK16） |
|---|---|---|
| 宏 M0 | `0x7702`（到 `0x7711`） | `0x7700`（到 `0x777F`） |
| 键盘自定义键 0 | `0x7F00` | `0x7E00` |

完整对照见 `sources/via-keycodes/v11.ts` 和 `v12.ts`（VIA 官方源码）。MacPulse 读到的协议版本和型号表不一致时，只显示不修改。

## 灯光

两把键盘的灯光都走自定义值命令（`0x07` / `0x08` / `0x09`），但 channel 和值编号不同：

| | BUFF67（QMK rgblight） | BNK16（固件自带灯效） |
|---|---|---|
| channel | 2 | 1 |
| 亮度 | id 1，0–255 | id 2，1–255 |
| 效果 | id 2（0 = 关） | id 1（0 = 关，1–20） |
| 速度 | id 3（MacPulse 不用） | id 3，1–5 |
| 颜色 | id 4，`[色相, 饱和度]` 各 0–255 | id 4，`[色相, 饱和度]`，只在效果 4（常亮）时有用 |
| 灯珠 | 只有一颗指示灯 | 背光 |

BUFF67 的效果值就是 QMK rgblight 的 mode 编号（1 常亮，2–5 呼吸，6–8 彩虹，9–14 彩虹漩涡……37–42 闪烁），MacPulse 只列出适合单颗灯的几种，完整列表见 `data/keyboards.json`。BNK16 的 21 种效果名称来自它的 VIA 定义。

`0x07` 设的值立即生效但不保存，键盘重新插拔后恢复；`0x09 channel` 才写进 EEPROM。MacPulse 拖动滑块时只发 `0x07`（多次改动合并，约 60 ms 发一次），点“应用”时依次写亮度、速度、颜色，最后写效果，再发 `0x09`。

## 宏编码

宏缓冲区里依次放所有宏，每个宏以 `0x00` 结尾。宏内部：

| 字节 | 含义 |
|---|---|
| 普通 ASCII 字符 | 按美式键位打出这个字符 |
| `01 01 kc` | 点按键码 `kc`（1 字节基本键码） |
| `01 02 kc` | 按下 |
| `01 03 kc` | 松开 |
| `01 04 数字… 7C` | 等待毫秒数，数字是 ASCII，以 `|` 结束 |

例：`"Hi"`，回车，空宏，`⌘ 按下 → C → ⌘ 松开 → 等 150 ms` 编码为：

```
48 69 01 01 28 00  00  01 02 E3 01 01 06 01 03 E3 01 04 31 35 30 7C 00
```

写宏时 MacPulse 把整个缓冲区（不足的补 0）写满，避免旧宏的残留字节接到新宏后面。

## 写入流程

1. 读出当前状态（协议版本、层数、全部键位、旋钮、宏、灯光）。
2. 本次启动第一次写这把键盘前，把第 1 步的状态存成备份（格式见下）。
3. 只发送和当前状态不同的键（`0x05`）、旋钮（`0x15`）；宏有变化时整块重写（`0x0F`）；灯光有变化时写入并保存。
4. 重新读整把键盘，逐项核对键位、旋钮、宏（按编码比较）和灯光（只比较这个效果用得到的字段），不一致就报错。

## 备份文件格式

`~/Library/Application Support/MacPulse/Keyboards/<型号>/<yyyy-MM-dd HHmmss>.json`，每把最多留 20 份。字段：

```jsonc
{
  "model": "BNK 16",
  "date": "2026-10-23T10:56:04Z",
  "layers": 10,
  "keymap": [[95, 96, …], …],          // 每层 rows × cols 个键码（十进制）
  "encoders": [[[190, 189], …], …],     // [层][旋钮][逆时针, 顺时针]
  "macroCount": 18,
  "macroBufferSize": 1008,
  "macroBytes": [0, 0, …],              // 上面的宏编码
  "lighting": {"effect": 4, "brightness": 255, "speed": 5, "hue": 251, "saturation": 1}
}
```

恢复时先检查层数、每层键数、旋钮数、宏数量和缓冲区大小都一致，再走第 3、4 步。

## 识别键盘

macOS 上 MacPulse 用 IOHIDManager 匹配 `Primary Usage Page 1 / Usage 6`（键盘），只读 `Transport`、VID、PID、`LocationID`、产品名，不打开设备，所以不需要“输入监控”权限。只保留 `Transport == "USB"`，排除 WLMOUSE（`0x36A7`）和罗技（`0x046D`）的接收器，以及名字含 receiver、dongle、mouse、接收器的设备。同型号的两把键盘用 `LocationID` 区分。
