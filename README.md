# MacPulse

原生菜单栏监控工具。本机部署适配环境为 **MacBook Pro（Mac14,9）/ Apple M2 Pro / 16 GB / macOS 27.0.1**。原始版本另在 Apple M5 Pro / 48 GB 上验证。

本机只读硬件诊断已确认：10 个 CPU 核心、CPU/GPU 占用率与温度、SMC 系统功耗、93 项温度传感器、两路风扇、物理网卡完整计数及磁盘读写均可读取。风扇停转时会正常显示 0 RPM。内存容量与硬件名称由系统自动读取。

本机内置 Retina 屏幕为 1512 × 982 逻辑点、2 倍缩放，可用高度 949 pt，能够容纳完整的 530 pt 面板；已检查完整深色面板与 480 pt 紧凑浅色面板的离屏渲染。安装位置为 `~/Applications/MacPulse.app`，已通过安装后签名验证、内置自检及真实硬件诊断。

## 界面

2.0 版下拉面板仅显示总览，使用 330 pt 宽度，顶部分为“系统 / 外设 / AI 用量”三页并记住上次所在页；四项核心指标以带彩色曲线的卡片显示，内存与磁盘附用量条，正文不小于 10 pt，网络与内存/磁盘并排显示，名称和数值就近排列，无需上下滚动。底部齿轮打开正常窗口，提供菜单栏自定义、传感器、进程、常规设置、提醒和 AI 用量。设置窗口采用左侧边栏导航（与系统设置一致），浅灰底配白色分组卡片，说明文字不小于 11 pt，菜单栏预览固定在顶部，传感器以紧凑双列列表显示。界面使用 SwiftUI 和 AppKit 原生毛玻璃材质，跟随系统明暗模式及辅助功能设置。

## 使用

双击 `MacPulse.app`。应用常驻顶部菜单栏，不显示 Dock 图标。默认按三组双行显示 **CPU / 内存、上传 / 下载、功耗 / 温度**；点击打开总览，右键可打开设置或退出。

- **总览**：功耗、CPU/GPU 温度与占用率、内存、交换空间、网络上下行、磁盘容量和读写、风扇转速、系统负载与开机时间；CPU / GPU / 神经网络引擎分项功耗；电池电量、健康度与循环次数；CPU 或内存占用最高的 3 个进程（可切换）。
- **进程页**：CPU 与内存占用最高的各 10 个进程。普通权限只能读取本用户进程，系统进程（如 WindowServer）不列出并注明数量。
- **提醒页**：系统通知提醒，默认关闭。可选 CPU 温度持续过高、内存压力紧张、磁盘空间不足、低电量未充电、Codex / Claude 剩余额度过低。每项触发后只提醒一次，恢复后重新计时；温度有 5 °C 回差，避免反复提醒。
- **底部齿轮**：打开正常窗口。“传感器”页分类查看硬件读数，“常规”页调整采样间隔、网络接口、登录启动等。
- **菜单栏自定义（小部件）**：菜单栏由最多 10 个独立小部件拼成，每个小部件可选文字、双行、迷你（小标签在上）、折线、柱状（CPU 为每核负载）、环形、电池 7 种样式，各自选择指标、标签（文字 / 图标 / 不显示）、自定义文字或图标、颜色（10 种）。设置页显示每种样式的实时缩略图，可拖动或用箭头排序、复制、删除。整体可调数值宽度（统一 / 按内容）、数值对齐、字号 8–13 pt、间距、分隔线；菜单栏图标有 26 种可选，可放在左侧或右侧。“布局预设”可把当前的小部件排列、样式和整体外观保存下来（最多 20 个，可命名、重命名、复制、排序、删除），以实时缩略图显示，点击即切换，切换后可撤销；从某个预设改动后会标出“有未保存的修改”，可一键还原或更新回该预设。另有参考布局、简洁、性能、图表、图标 5 个内置预设，可复制到“我的预设”再改。菜单栏图标右键菜单的“布局预设”子菜单也能直接切换。1.6 及以前的分组设置会自动迁移，外观不变。
- **鼠标 / 外设电量**：每分钟读取一次无线外设电量，显示在总览底部、“常规”页和可选的菜单栏小部件（支持电池、环形样式）。WLMOUSE 无线接收器（厂商 ID 0x36A7）通过官方网页驱动 gm.wlmouse.gg 使用的同一条只读查询（64 字节 Feature Report，命令 0x83）读取电量和充电状态，不写入任何鼠标设置；向系统报告 BatteryPercent 的蓝牙外设直接读取。鼠标休眠时接收器返回 0，保留上次读数并标明时间。
- **鼠标设置（设置 → 外设）**：WLMOUSE 新协议型号（花•兽 Mini / Mini PRO / X / X PRO / MAX / X V2、幻、幻 M、影、剑 X、行者、MIAO、BEAST G）可调 DPI 档位（含 X/Y 分别设置、当前档位）、回报率、静默高度、按键去抖动、休眠时间、角度微调、Motion Sync、直线修正、波纹控制、高速模式与竞技模式，并切换板载配置、为配置命名（名称保存在鼠标里，GBK 编码，与官方驱动通用）。命令与取值范围取自官方网页驱动 gm.wlmouse.gg 公开的脚本与型号表；修改先放在草稿里，点“应用到鼠标”才写入，写入后逐项读回校验。花•兽 Mini PRO（8K 接收器）已实机验证读写。固件升级、重新配对、恢复出厂、按键与宏不提供，请用官方驱动。
- **风扇预设（设置 → 风扇，默认关闭）**：“自动”加四个场景预设——静音办公（70 °C 前保持最低转速）、日常均衡（55 °C 起平缓加速）、持续性能（编译、导出、本地模型时提前加速，减少长时间负载下的降频）、极限散热（游戏与满载，温度优先）。另可新建、命名并保存自定义曲线（横轴 CPU 温度 30–100 °C，纵轴风扇转速占比并标注 RPM），拖动圆点或双击添加，每条最多 4 个点，图上标出当前温度与对应转速。多风扇的 Mac（如 MacBook Pro）会逐个列出风扇，可以给每个风扇起名字；同一条自定义曲线里可以为每个风扇单独调整（顶部切换风扇，其他风扇的曲线以虚线显示，“复制到所有风扇”一键统一），没单独调过的风扇跟随第一个风扇，转速都按各风扇自己的最低–最高范围的百分比计算。没有风扇的 Mac（如 MacBook Air）不显示风扇页和风扇单元。任何预设下 CPU 达到安全温度（85 / 90 / 95 °C）时系统临时接管，降到安全线 5 °C 以下自动恢复。面板“系统”页的风扇单元可一键切换四个钉选的预设或自定义曲线。已在 Mac mini（M5 Pro）实测：设定 2000 RPM 后 2 秒内到位并保持，交还自动后回到 1000 RPM。
- **罗技设备（HID++ 2.0，未经实机测试）**：电量（0x1004 / 0x1000）、DPI（0x2201）、SmartShift 与滚轮模式（0x2110 / 0x2111）、滚轮反向（0x2121）。协议实现参考 [OpenLogi](https://github.com/AprilNEA/OpenLogi)（MIT / Apache-2.0）。部分接收器需要在“系统设置 → 隐私与安全性 → 输入监控”中允许 MacPulse；每次重新编译后 ad-hoc 签名会变化，可能需要重新授权。
- **固定宽度**：数值区、分组以及整个状态栏项的宽度仅根据配置计算，不测量实时字符串来调整宽度。等宽数字右对齐，网速切换单位时不会移动相邻元素。极端超长值在原位置截断；修改指标、标签、字号或布局时才重新计算宽度。全部隐藏时仍保留图标入口。
- 面板右上角的图钉可以固定面板；再次点击菜单栏图标或关闭按钮可收起。
- 面板高 530 pt，分“系统”“外设”“AI 用量”三页：系统页顶部为 CPU、GPU、内存、温度四个圆环，中间是风扇单元（左侧每个风扇一条转速条，显示自定义名称和 RPM；右侧四个预设按钮，按钮在“设置 → 风扇”用图钉选择），下面并排三张卡片：网络（下载为主数值、上传在下方，附曲线）、功耗（本次耗电与曲线）、磁盘可用（总容量与用量条），最后是占用最高的 3 个进程（可按 CPU 或内存排序）；核心负载、芯片功耗、系统负载、内存与磁盘明细、IP 等移到“设置 → 传感器”顶部的“系统概要”；外设页显示鼠标电量、近 7 天电量曲线与预计续航（每 10 分钟记录一次，仅存本机）、配置切换（显示自定义名称）、当前 DPI、回报率、静默高度与休眠时间，鼠标休眠时提示动一下即可；AI 用量页使用完整尺寸的正方形活动热力图、近 14 天每日费用柱状图，以及“刷新额度”“打开用量网页”按钮。系统页的读数都可以点击跳转：CPU、GPU 圆环和按 CPU 排序的进程打开活动监视器的 CPU 页，内存圆环和按内存排序的进程打开内存页，网络行打开网络页，功耗打开能耗页，磁盘可用空间打开磁盘工具，温度和风扇转速条打开 MacPulse 的传感器 / 风扇设置，底部电池打开系统设置的电池页。活动监视器只在启动时读取上次的标签页，若它已在别的页上运行，MacPulse 会让它正常退出后在目标页重新打开；已在目标页时只切到前台。“系统概要”中点击 IP 即复制。底部显示运行时长和本机电池。屏幕可用高度较小时页面内可滚动；历史曲线保留最近两分钟，启动后逐渐积累。
- 要在登录时启动，请将应用放在 `~/Applications` 或 `/Applications`，再在设置中打开“登录时启动 MacPulse”。系统要求批准时，前往“系统设置 → 通用 → 登录项”。默认不自动开启。

## AI 用量与自定义额度

总览中的服务按钮切换 AI 服务，显示今日、近 7 天、累计 Token 及估算费用和近半年活动热力图。Codex 与 Claude 始终显示；Gemini、Qwen、OpenCode、Grok Build 等其他 agent 有用量记录后自动出现（服务超过 3 个时改为下拉菜单）。其他 agent 只统计用量与估算费用，不查询账户额度。点击小格查看当天读数，右上角详情按钮直接打开“AI 用量”设置。

- **数据来源**：默认优先只读 CC Switch 的用量记录（`~/.cc-switch/cc-switch.db` 中的 `proxy_request_logs` 与 `usage_daily_rollups`，不读取服务商凭据表）。其中有记录的每个应用都会自动显示。CC Switch 能解析 Codex 压缩为 `.jsonl.zst` 的旧会话，并在清理明细后保留按天汇总，费用按其价格表和服务商倍率计算；Token 合计沿用 CC Switch 的口径（按 `input_token_semantics` 归一为新增输入 + 输出 + 缓存写入 + 缓存读取，Codex / Gemini / Grok Build 的输入本身含缓存）。某个应用在 CC Switch 中没有记录时，改读它的本机日志。未安装 CC Switch 或关闭该选项时，回退到下方的本机日志扫描，并提示有多少个压缩会话无法读取（macOS 不自带 zstd 解码）。
- **其他 agent 的本机日志**：Gemini CLI（`~/.gemini/tmp/*/chats/` 中的 `.json` / `.jsonl` 会话记录，按会话与消息 ID 去重，输入是否含缓存按记录中的 total 判断）、Qwen Code（`~/.qwen/projects/*/chats/*.jsonl` 的 usageMetadata）、OpenCode（1.2 起的 `~/.local/share/opencode/opencode.db`，以及旧版 `storage/message/` 下的消息文件，两者按消息 ID 去重，直接采用 OpenCode 记录的费用）。各格式参考 [tokscale](https://github.com/junhoyeo/tokscale) 的整理。
- **费用估算**：本机日志模式按内置的 API 公开标价（2026-10）估算；内置表没有的模型（如 Gemini、Qwen 系列）使用 CC Switch 的价格表，区分未缓存输入、缓存写入（5 分钟 1.25 倍、1 小时 2 倍）、缓存读取和输出；不在价格表中的模型显示“无标价”。订阅套餐不按 Token 计费，金额不等同于账单。设置页按模型列出次数、Token 和费用。
- **多台 Mac 汇总（可选，默认关闭）**：开启后每台 Mac 向“iCloud 云盘/MacPulse”写入一个只含按天 Token 数与估算费用的小文件，不含会话内容、路径或账户信息，并合并其他 Mac 的文件；模型明细只显示本机。
- **额度倒计时与服务状态**：额度窗口显示“2 小时 13 分后重置”式倒计时，悬停可看具体时间。随额度查询一起读取 status.openai.com / status.claude.com 的公开状态，有故障时在服务名旁显示提示，可在设置中关闭。

- 自定义额度：在“设置 → AI 用量”选择服务，启用“使用自定义额度”，填写总额度、已用额度、单位和周期，点击“保存额度”。剩余 = max(0, 总额度 − 已用额度)。Codex / Claude 独立保存。
- 单位支持 USD、CNY、Token、次数、百分比。自定义额度是手动台账，不会按本地 Token 自动扣款；可选择不重置，或在本机时区每日零点、周一零点、每月 1 日将已用归零。“已用归零”立即保存。
- Codex：读取本机 `.codex/sessions` 和归档日志，按 response ID 去重；旧日志按累计值差分。缓存输入已包含在总 Token 内，不重复累加。
- Claude：读取本机 `.claude/projects`，按 assistant message ID 合并流式和重复记录；累计输入、缓存读取、缓存创建、输出 Token。没有本地记录的日期显示空格。
- 本机统计不包含已删除记录、其他设备和未写入这些目录的会话，也不等同于账单金额。文件扫描每分钟一次，未变化的文件复用内存缓存；仍在写入的会话文件只读取新增行（校验已读末尾，被改写的文件重新解析）。
- 自动额度：Sub2API 从当前 Codex 配置及相同服务地址的 CC Switch 当前凭据读取 `/v1/usage`；官方 Codex 支持已有 `auth.json` OAuth 登录；Claude 使用标准 Claude Code OAuth 凭据（连接按钮可请求钥匙串访问）。桌面账户信息本身不等于可读取的 Claude Code 凭据：只登录了 Claude 桌面版时，令牌由桌面应用加密保存，MacPulse 不会读取，设置页会提示安装命令行版 Claude Code（`curl -fsSL https://claude.ai/install.sh | bash`）并运行 `claude` 登录一次，再点“连接本机 Claude Code”。
- 额度过期、权限不足、服务拒绝或缺少登录时显示原因，不把未知显示为 0。保留的旧值会标记“旧数据”。提供商返回的账户额度与自定义台账始终明确区分。

接口依据：[OpenAI Codex 账户额度文档](https://learn.chatgpt.com/docs/app-server)、[Claude 状态栏额度字段](https://code.claude.com/docs/en/statusline)、[Sub2API 官方实现](https://github.com/Wei-Shaw/sub2api/blob/main/backend/internal/handler/gateway_handler.go)。Claude OAuth 查询方式参考 [CodexBar 的 Claude 实现说明](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)，该接口可能随后续服务更新而变化。

## 数据口径

| 指标 | 来源与含义 |
| --- | --- |
| 系统功耗 | 优先读取 AppleSMC `PSTR`，单位 W。不是外接功率计测得的插座功率，也不是 CPU 单独功耗。不可用时尝试 IORegistry 的系统输入功率，并标明来源。 |
| 芯片分项功耗 | macOS 27 上 IOReport “Energy Model” 计数器在无私有授权时不再更新，改为读取 AppleCLPC 的 CPU / GPU / 神经网络引擎累计能耗（nJ），按两次读数差值除以时间得到平均功率。各芯片的计数器 ID 参照 [macmon](https://github.com/vladkens/macmon)（MIT），只在 macOS 27 和已知芯片上启用，否则显示 —。分项已包含在系统功耗中。 |
| 进程 | `proc_pid_rusage` 的 CPU 时间差（Mach 时基换算）与物理占用（与活动监视器“内存”列口径一致）。CPU 为占单个核心的百分比。仅在面板或设置窗口可见时采集。 |
| 电池健康 | AppleSmartBattery 的标称满充容量 ÷ 设计容量（mAh），以及循环次数与设计循环次数。读数会随温度和校准小幅波动。 |
| 温度 | AppleSMC 可读取的传感器。CPU/GPU 摘要取对应温度组的最高值；具体值可在传感器页检查。 |
| 本次运行 Wh | 对本次运行期间的可用功率采样做梯形积分。睡眠、退出和缺失数据期间不计入，属于采样估计值。 |
| CPU | Mach 各核心 CPU tick 的差值，汇总为 0–100%，展示用户、系统占比与各逻辑核心。 |
| GPU | 驱动 `IOAccelerator` 的 `Device Utilization %`；不可读取时显示 —。 |
| 内存 | 从 Mach VM 页面统计估算已用物理内存，排除可清除页面与文件缓存，包含压缩内存；可能与活动监视器的瞬时读数略有差异。 |
| 网络 | Wi-Fi / 以太网 `en*` 物理接口，默认合计，也可单独选择。通过系统自带 netstat 读取完整 64 位计数，按单调时钟差值计算速率；排除 VPN、回环、AirDrop 与桥接口，避免重复累计。普通应用在当前系统读取 NET_RT_IFLIST2 仍会得到截断计数，因此不能仅依据其 64 位字段声明判断精度。系统工具失败时退回原生计数并保护重置；数据源切换时重置基线。 |
| 磁盘 | 容量为用户主目录所在卷；读写速率为所有可读取的块存储驱动合计，可能包括外接磁盘和已挂载磁盘映像。 |
| 单位 | KB/MB/GB 使用 1024 进位；总览网速为字节/秒。菜单栏也可切换为比特/秒（b/s，1000 进位）。 |

无法读取的核心传感器数据以 `—` 显示，不伪造数值。睡眠时暂停采样，唤醒后重置差分基线；网络接口重连与计数器回退不会产生负数或巨大速率峰值。

AppleSMC 和 GPU 驱动统计不是稳定的公开 API。此版本针对当前这台 Apple Silicon Mac 验证；其他机型或后续 macOS 更新可能需要适配。默认情况下应用仅读取传感器，不写入 SMC、不调节风扇、不安装内核扩展或提权服务。风扇控制是可选功能，默认关闭：在“设置 → 风扇”中开启时，经管理员密码确认，安装一个以 root 运行的风扇助手（`/Library/PrivilegedHelperTools/local.macpulse.fanhelper`，LaunchDaemon `local.macpulse.fanhelper`）。SMC 写入代码只编译进这个助手，菜单栏应用本身仍是只读的；助手只接受“查询 / 自动 / 设定转速 / 心跳”四个命令，套接字仅安装者账户可连接，转速限制在风扇自身最低与最高之间，45 秒无心跳或收到 SIGTERM 即交还系统控制；可在设置中一键移除。风扇写入顺序参照 [Stats](https://github.com/exelban/stats)（MIT）：M5 及以后直接写模式键（`F0md`），M1–M4 需先设置 `Ftst`。

硬件采样和会话用量在本机处理，不上传会话内容或硬件数据，不持续写入日志。账户额度查询每 5 分钟通过 HTTPS 访问已配置服务商或对应官方账户服务，同时（可关闭）读取两家公开状态页，不附带任何凭据或本机数据；检测更新每天访问一次 api.github.com（可关闭）；只有开启“多台 Mac 汇总”后才会向 iCloud 云盘写入按天汇总；登录凭据仅在内存使用，不写入本项目，也不跟随重定向。设置使用标准 UserDefaults 保存；只有主动点击“复制诊断信息”才写入剪贴板。

## 源码与构建

需要 Apple Silicon Mac、macOS 14 或更高版本，以及 Xcode Command Line Tools。当前已在 Swift 6.4 工具链验证。没有第三方依赖；使用 SwiftUI、AppKit、Mach、IOKit、IOReport、UserNotifications 和 ServiceManagement。网络统计通过 posix_spawn 直接运行系统自带 /usr/sbin/netstat，不经过 shell、不需要 sudo。

### 资源占用（1.5 版，M2 Pro 实测）

| 项目 | 1.4 | 1.5 |
| --- | --- | --- |
| 单次采样（面板关闭） | 约 107 ms | 约 12 ms |
| 单次采样（面板打开，含进程） | 约 107 ms | 约 40 ms |
| 启动网络计数 netstat | 约 74 ms（Foundation Process） | 约 4.5 ms（posix_spawn） |
| AI 日志首次扫描（177 MB Claude 日志） | 4.3 s，峰值内存约 200 MB | 0.66 s，峰值内存约 28 MB |

面板和设置窗口都关闭时不再触发 SwiftUI 刷新，温度与分项功耗每 3 秒读取一次，菜单栏只在显示内容变化时重绘；屏幕休眠时采样降到 5 秒一次。

获取源码并编译安装：

```bash
git clone https://github.com/liiuuumemory/MacPulse.git
cd MacPulse
bash build.sh
```

已有源码时，在项目目录直接运行：

```bash
bash build.sh
```

默认安装到 `~/Applications/MacPulse.app`，避免将可执行应用放在文件同步服务管理的文档目录；也可指定输出目录：

```bash
bash build.sh /path/to/output
```

编译缓存默认存放在临时目录，可通过 `MACPULSE_BUILD_DIR` 环境变量指定。C 与 Swift 均明确编译为 arm64。构建脚本会清除生成应用的附加属性，并做本地 ad-hoc 签名及签名验证；复制到目标目录后再次清理、签名和验证，防止文件同步服务在复制时附加 Finder 元数据导致产物不可用。构建产物用于本机运行，未做 Apple 公证；向其他 Mac 分发时建议使用 Developer ID 签名并公证。

```bash
"$HOME/Applications/MacPulse.app/Contents/MacOS/MacPulse" --test
"$HOME/Applications/MacPulse.app/Contents/MacOS/MacPulse" --diagnose
```

`--test` 检查不同网速和单位下的单行 / 双行固定宽度、数值是否容纳于预留区域、配置序列化、全空配置入口，以及网络计数、功耗积分、历史清理、AI 用量去重与缓存、增量续读、费用估算、CC Switch 记录合并、iCloud 汇总合并、提醒的持续 / 锁存 / 回差 / 冷却、自定义额度保存和周期重置、额度响应解析与未知/零值区分。自检不会修改真实设置。`--diagnose` 采集真实数据并输出 JSON，包括面板打开与关闭两种情况下的单次采样耗时、分项功耗、电池健康和 CPU 最高的进程，不需要 sudo。不要在限制硬件访问的执行沙箱中将不可用误认为传感器不存在。

可使用 `--snapshot /absolute/path.png` 渲染总览，附加 `--snapshot-tab menu` / `settings` / `sensors` / `processes` / `alerts` / `ai` 渲染设置窗口，`--snapshot-tab bar` 渲染实际菜单栏。附加 `--dark` 检查深色模式，`--compact` 检查 480 pt 高的紧凑总览。`--simulate-fans N`（0–3）用模拟的风扇数量渲染，检查无风扇和多风扇布局。离屏预览使用中性背景，实际毛玻璃由系统合成；这不是桌面截屏。`--settings` 可直接打开正常设置窗口。

## 检测更新

“设置 → 常规 → 工具与关于”可手动检查更新，默认每天自动检查一次（可关闭）。检查只读取 [GitHub Releases](https://github.com/liiuuumemory/MacPulse/releases) 的最新版本号和发布说明，不发送本机数据，不会自动下载或安装。发现新版本时，面板底部显示“新版本”按钮。

`build.sh` 会把源码所在目录写入生成应用的 Info.plist（只存在于本机构建产物中）。如果该目录是 `git clone` 得到的仓库，设置页提供“复制更新命令”，粘贴到终端运行即可：

```bash
git pull && bash build.sh
```

运行后重新打开 MacPulse。

## 文件结构

- `Source/Metrics.swift`：CPU、内存、网络、磁盘、GPU、功耗和传感器采集。
- `Source/Sensors.c` / `Sensors.h`：只读 SMC 协议、64 位网络计数器、netstat 调用及 AppleCLPC 分项能耗。
- `Source/Monitor.swift`：后台定时采样、历史数据、设置、睡眠恢复。
- `Source/Panel.swift`：330 pt 毛玻璃面板（系统 / 外设 / AI 用量三页）。
- `Source/MenuBar.swift`：配置、固定宽度布局、文字绘制和菜单栏编辑器。
- `Source/Preferences.swift`：正常设置窗口、传感器与常规设置。
- `Source/AIUsage.swift`：本机会话 Token 去重统计、增量续读、费用估算、CC Switch 记录读取与自定义额度。
- `Source/AgentLogs.swift`：Gemini CLI、Qwen Code 与 OpenCode 的用量记录读取。
- `Source/UsageSync.swift`：可选的 iCloud 云盘多设备按天汇总。
- `Source/Alerts.swift`：提醒规则与系统通知。
- `Source/Updater.swift`：GitHub Releases 检测更新。
- `Source/Peripherals.swift`：无线外设电量读取（WLMOUSE、罗技、系统报告的蓝牙外设）。
- `Source/WLMouse.swift`：WLMOUSE 型号表与设置命令（读、写、读回校验）。
- `Source/Logitech.swift`：罗技 HID++ 2.0 通道与电量、DPI、SmartShift、滚轮方向。
- `Source/MouseSettings.swift`：设置窗口“外设”页与鼠标设置的读写调度。
- `Source/FanControl.swift`：风扇预设（按 CPU 温度的转速曲线）、助手安装与卸载、安全回退、“风扇”设置页。
- `Source/SystemJump.swift`：面板读数的点击跳转（活动监视器标签页、磁盘工具、系统设置、MacPulse 设置页）。
- `Source/FanHelper/main.swift`：可选的 root 风扇助手（唯一包含 SMC 写入的程序）。
- `Source/QuotaClient.swift`：只读账户额度查询，支持 Codex、Claude OAuth 和 Sub2API。
- `Source/AIUsageViews.swift`：服务切换、热力图、额度和自定义配置。
- `Source/AIUsageTests.swift`：独立样本测试，不修改真实账户额度。
- `Source/main.swift`：菜单栏、弹出面板、自检与渲染入口。
- `build.sh` / `Info.plist` / `AppIcon.icns`：可复现构建所需文件。
- `CHANGELOG.md`：更新记录。

芯片分项功耗使用的 AppleCLPC 计数器 ID 与通道描述格式来自 [macmon](https://github.com/vladkens/macmon)（Copyright (c) 2024 vladkens，MIT License）。传感器键名可参照 [Stats 项目硬件键名资料](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)；本工具的采集器和界面独立实现。WLMOUSE 命令与型号参数取自官方网页驱动 gm.wlmouse.gg 公开的脚本与型号表；罗技 HID++ 报文格式与功能编号参照 [OpenLogi](https://github.com/AprilNEA/OpenLogi)（MIT / Apache-2.0），以 Swift 独立实现。系统接口定义以本机 macOS SDK 为准。

## 卸载

先在设置中关闭“登录时启动”，再通过右键菜单退出，最后移除 `MacPulse.app`。没有后台提权服务需要清理。

菜单栏各组统一采用 CPU 使用率组的宽度；网速以 999KB/s、1.2MB/s 等紧凑格式显示。长标签会省略，悬停可查看完整指标读数。
