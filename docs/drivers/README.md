# 外设驱动资料

MacPulse 鼠标和键盘驱动用到的全部资料：协议说明、型号表与键码表、设备的原始定义文件、本机实测数据和调试工具。用来把驱动移植到 Windows，或者做更完整的驱动项目。

协议说明根据 MacPulse 已经实现并在真机上验证过的代码整理，不是推测。代码以 `Source/` 为准，这里的 `data/` 由代码导出。

## 目录

```
docs/drivers/
├── README.md                         本文件：索引、移植指引、来源
├── protocols/
│   ├── via-keyboard.md               VIA 键盘：接口、命令、固件怪癖、v11/v12 差异、灯光、宏编码、写入与备份
│   ├── wlmouse.md                    WLMOUSE：Feature 报告格式、命令表、编码、电量
│   ├── logitech-hidpp.md             罗技 HID++ 2.0：消息格式、用到的功能（未实测）
│   └── discovery-and-battery.md      设备识别与蓝牙电量（macOS 做法与 Windows 思路）
├── data/                             由 MacPulse 导出的机读表，可直接给其他语言用
│   ├── keyboards.json                两把键盘：VID/PID、矩阵、协议版本、每个键的位置与尺寸、旋钮、灯光 channel 与效果列表、自定义键
│   ├── keycodes.json                 键码 → 显示名（基础、小键盘、修饰、媒体、灯光、层功能、组合键编码规则、禁用键）
│   ├── mac-virtual-keycode-to-hid.json   macOS 虚拟键码 → HID 用途码（“按键录入”用）
│   └── wlmouse-models.json           WLMOUSE 13 个型号：各 PID 的回报率、DPI 上限与步进、LOD、功能开关
├── sources/                          第三方原始文件（出处见下）
│   ├── via-definitions/
│   │   ├── BUFF67v3r2.json           这把 BUFF67 实际对应的 VIA 定义（VID/PID 0xB710）
│   │   ├── BNK16-CONFIG(USB).json    Binepad 官方给 BNK16 有线版的 VIA 定义（含灯光与触感菜单）
│   │   ├── buff67v3-upstream-ommk.json        上游 buff67v3（0xAA96/0xAA88），布局相同但 ID 不匹配本机
│   │   └── buff67v3-upstream-the-via-yr65kb.json   VIA 官方仓库里的同一块板
│   ├── via-keycodes/v11.ts, v12.ts   VIA 官方的键码表（协议 11 和 12）
│   └── qmk/buff67v3-keyboard.json    QMK 上游 buff67v3 的板子定义（STM32F103，引脚、灯光）
├── devices/                          本机实测（2026-10-23，macOS 27，Mac mini M5 Pro）
│   ├── bnk16/                        只读导出、HID 接口、报告描述符、写入前的自动备份
│   ├── buff67v3r2/                   同上；两份备份分别是回环测试前和你在应用里改 ⌘/⌥ 之前
│   └── wlmouse/                      花•兽 Mini PRO 8K 接收器：HID 接口、报告描述符、设置只读导出
└── tools/
    └── via-probe.swift               命令行 VIA 探测工具：任意命令发一条看一条回复
```

## 重新生成

`data/` 来自代码里的型号表和键码表，改了 `Source/Keyboard.swift` 或 `Source/WLMouse.swift` 之后重新导出：

```bash
"$HOME/Applications/MacPulse.app/Contents/MacOS/MacPulse" --export-driver-data docs/drivers/data
```

设备的当前状态用只读导出刷新（`--raw` 会附上每层的原始键码）：

```bash
"$HOME/Applications/MacPulse.app/Contents/MacOS/MacPulse" --keyboard-dump --raw
```

## 移植到 Windows

三类设备用的都是厂商自定义的 HID collection，和系统独占的键盘、鼠标 collection 分开，Windows 上可以直接用 hidapi 或 `HidD_*` 打开，不需要内核驱动。

| 设备 | 找接口 | 发送 | 接收 |
|---|---|---|---|
| VIA 键盘 | usage page `0xFF60`，usage `0x61` | `hid_write`：`0x00` + 32 字节 | `hid_read` 32 字节，第 0 字节回显命令 |
| WLMOUSE | VID `0x36A7`，usage page `0xFFFF`，最大 Feature 64 字节 | `hid_send_feature_report`：`0x00` + 64 字节 | `hid_get_feature_report` 65 字节，状态 `0xA1` 表示完成 |
| 罗技 | VID `0x046D`，usage page `0xFF00` / usage `0x0002`（蓝牙 `0xFF43` / `0x0202`） | `hid_write`：Report ID `0x11` + 19 字节 | `hid_read`，按设备号、功能下标、function 配对 |

建议照搬的部分：

- 型号表、键码表、宏编码、灯光 channel 和效果列表直接读 `data/*.json`，不要手抄。
- 写入一律“只发改了的部分，写完整体读回核对”，第一次写入前先备份；备份格式见 `protocols/via-keyboard.md`，Windows 版可以读写同一种文件。
- 永远不发的命令和不提供的键码见 `protocols/via-keyboard.md` 的“永远不发的命令”。BNK16 不能发 `0x02`，读键位不能跨层。
- 键盘绘制用 `keyboards.json` 里每个键的 `x / y / w / h`（单位是 1u 键宽），旋钮用 `knobs` 的 `x / y / size`。

要重写的部分：设备识别（`discovery-and-battery.md`）、蓝牙电量、“按键录入”的键码映射（Windows 用虚拟键码或扫描码映射到 HID 用途码，`mac-virtual-keycode-to-hid.json` 只适用于 macOS）。

## 想做得更完整

现在没做、但资料里已经有线索的：

- **BNK16 触感（振动）**：定义里的 `touch feeling` 菜单在 channel 2（强度 id 1、上升 id 2、下降 id 3、保持 id 4、频率 id 5，id 6 是“保存”按钮），选项值见 `BNK16-CONFIG(USB).json`。你说过它有实体按钮，MacPulse 没做。
- **BNK16 的 `0xF1` / `0xF2`**：矩阵 `(0,4)`、`(1,4)` 每层都是这两个键码，但它们不在 VIA 布局里，VIA 的键码表里也没有这两个值，用途还不清楚。
- **QMK rgblight 全部效果**：BUFF67 的完整效果编号见 `qmk/buff67v3-keyboard.json` 里启用的动画和 QMK 文档；MacPulse 只列了适合单颗指示灯的几种。
- **读键盘信息**（`0x02`：运行时间、布局选项、固件版本、矩阵测试等）：BUFF67 回应了 `0x02 0x01`、`0x02 0x02`、`0x02 0x04`，矩阵测试没试过；BNK16 收到 `0x02` 会卡住。要用就得按型号区分。
- **WLMOUSE 按键映射、宏、固件升级**：命令不在 MacPulse 已用的范围内，需要另外抓网页驱动的通信。

## 来源与许可

| 文件 | 出处 | 许可 |
|---|---|---|
| `sources/via-definitions/BUFF67v3r2.json` | 你提供的 VIA 定义文件 | 厂商文件 |
| `sources/via-definitions/BNK16-CONFIG(USB).json` | Binepad：[BNK16 WR configurator](https://binepad.com/blogs/configurator/bnk16-wr-configurator) 页面里的 Google Drive 链接 | 厂商文件 |
| `sources/via-definitions/buff67v3-upstream-ommk.json` | [Oh-My-Mechanical-Keyboard release buff67v3](https://github.com/Oh-My-Mechanical-Keyboard/oh-my-mechanical-keyboard.github.io/releases/tag/buff67v3) | 见原仓库 |
| `sources/via-definitions/buff67v3-upstream-the-via-yr65kb.json` | [the-via/keyboards](https://github.com/the-via/keyboards) `v3/yandrstudio/buff67v3/yr65kb.json` | GPL-3.0 |
| `sources/via-keycodes/v11.ts`、`v12.ts` | [the-via/app](https://github.com/the-via/app) `src/utils/key-to-byte/` | GPL-3.0 |
| `sources/qmk/buff67v3-keyboard.json` | [qmk/qmk_firmware](https://github.com/qmk/qmk_firmware) `keyboards/yandrstudio/buff67v3/keyboard.json` | GPL-2.0 或更高 |
| 罗技协议细节 | [OpenLogi](https://github.com/AprilNEA/OpenLogi) | MIT / Apache-2.0 |
| 其他（`protocols/`、`data/`、`devices/`、`tools/`） | MacPulse | 同本仓库 |

第三方文件原样保存，只用作参考资料。如果以后的项目要直接引用或分发 GPL 文件，需要遵守对应许可。
