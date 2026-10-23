import Foundation

/// One key on a VIA layout, in key units from the board's top-left: matrix position plus size.
struct KeyboardKey: Identifiable, Hashable {
    let row: Int
    let col: Int
    let x: Double
    let y: Double
    var w: Double = 1
    var h: Double = 1
    var id: String { "\(row),\(col)" }
}

/// A rotary encoder: turning sends one keycode per direction; some also press as a matrix key.
struct KeyboardKnob: Identifiable, Hashable {
    let index: Int
    let x: Double
    let y: Double
    let size: Double
    var press: KeyboardKey?
    var id: Int { index }
}

/// Lighting a board exposes through VIA's custom value commands: channel plus value ids, as in its definition's menu.
struct KeyboardLighting {
    let channel: UInt8
    let effectID: UInt8, brightnessID: UInt8, speedID: UInt8?, colorID: UInt8?
    let effects: [(value: Int, name: String)]
    let brightness: ClosedRange<Int>
    let speed: ClosedRange<Int>?
    /// Effects whose color can be set; the rest pick their own colors.
    let colorEffects: Set<Int>
    /// A single indicator LED rather than per-key or underglow lighting.
    let indicatorOnly: Bool
    func effectName(_ value: Int) -> String { effects.first { $0.value == value }?.name ?? "效果 \(value)" }
}

struct KeyboardCustomKey {
    let short: String
    let name: String
    /// Factory reset, firmware update and similar keys stay out of the picker.
    var hidden = false
}

/// A supported VIA keyboard, from its VIA definition (matrix, layout, lighting menu, custom keycodes).
struct KeyboardModel {
    let name: String
    let vendorID: Int
    let productID: Int
    let rows: Int
    let cols: Int
    let keys: [KeyboardKey]
    let knobs: [KeyboardKnob]
    /// VIA protocol 11 keeps macros at 0x7702 and custom keys at 0x7F00; 12 moved them to 0x7700 and 0x7E00.
    let protocolVersion: Int
    let lighting: KeyboardLighting?
    let custom: [KeyboardCustomKey]
    let driverName: String
    let driverLink: String?
    var macroBase: UInt16 { protocolVersion >= 12 ? 0x7700 : 0x7702 }
    var customBase: UInt16 { protocolVersion >= 12 ? 0x7E00 : 0x7F00 }
    /// Board size in key units, for drawing.
    var width: Double { (keys.map { $0.x + $0.w } + knobs.map { $0.x + $0.size }).max() ?? 1 }
    var height: Double { (keys.map { $0.y + $0.h } + knobs.map { $0.y + $0.size }).max() ?? 1 }

    /// Builds keys from VIA/KLE rows: each entry is a width (1 for plain keys), a gap is a negative width.
    static func rows(_ layout: [[(String, Double)]]) -> [KeyboardKey] {
        var keys: [KeyboardKey] = []
        for (y, row) in layout.enumerated() {
            var x = 0.0
            for (label, w) in row {
                if label.isEmpty { x += w; continue }
                let parts = label.split(separator: ",").compactMap { Int($0) }
                keys.append(KeyboardKey(row: parts[0], col: parts[1], x: x, y: Double(y), w: w))
                x += w
            }
        }
        return keys
    }

    static let all: [KeyboardModel] = [buff67, bnk16]
    static func resolve(vendorID: Int, productID: Int) -> KeyboardModel? { all.first { $0.vendorID == vendorID && $0.productID == productID } }

    /// VLstudio BUFF67v3r2: 65% with a 2u backspace and 6.25u space; one RGB indicator LED (QMK rgblight).
    static let buff67 = KeyboardModel(
        name: "BUFF67v3r2", vendorID: 0xB710, productID: 0xB710, rows: 5, cols: 15,
        keys: rows([
            (0...12).map { ("0,\($0)", 1.0) } + [("0,13", 2), ("0,14", 1)],
            [("1,0", 1.5)] + (1...12).map { ("1,\($0)", 1.0) } + [("1,13", 1.5), ("1,14", 1)],
            [("2,0", 1.75)] + (1...11).map { ("2,\($0)", 1.0) } + [("2,13", 2.25), ("2,14", 1)],
            [("3,0", 2.25)] + (1...10).map { ("3,\($0)", 1.0) } + [("3,12", 1.75), ("3,13", 1), ("3,14", 1)],
            [("4,0", 1.25), ("4,1", 1.25), ("4,2", 1.25), ("4,6", 6.25), ("4,7", 1.25), ("4,11", 1.25), ("", 0.5), ("4,12", 1), ("4,13", 1), ("4,14", 1)],
        ]),
        knobs: [], protocolVersion: 11,
        lighting: KeyboardLighting(channel: 2, effectID: 2, brightnessID: 1, speedID: nil, colorID: 4,
                                   effects: [(0, "关闭"), (1, "常亮"), (2, "呼吸 · 慢"), (3, "呼吸"), (4, "呼吸 · 快"), (5, "呼吸 · 最快"),
                                             (6, "彩虹 · 慢"), (7, "彩虹"), (8, "彩虹 · 快"), (9, "彩虹漩涡"), (37, "闪烁")],
                                   brightness: 0...255, speed: nil, colorEffects: [1, 2, 3, 4, 5, 37], indicatorOnly: true),
        custom: [KeyboardCustomKey(short: "Win 锁", name: "锁定 Win 键"), KeyboardCustomKey(short: "Mac", name: "切换 macOS 键位"),
                 KeyboardCustomKey(short: "调度", name: "调度中心（Mission Control）"), KeyboardCustomKey(short: "启动台", name: "启动台（Launchpad）")],
        driverName: "VIA 定义：BUFF67v3r2.json", driverLink: nil)

    /// Binepad BNK16 (wired): 4×4 keys, two push knobs and a large knob; its own lighting effects on channel 1.
    static let bnk16 = KeyboardModel(
        name: "BNK 16", vendorID: 0x1A86, productID: 0xFC16, rows: 5, cols: 5,
        keys: rows((0...3).map { r in (0...3).map { ("\(r),\($0)", 1.0) } }),
        knobs: [KeyboardKnob(index: 0, x: 4.5, y: 0, size: 1, press: KeyboardKey(row: 4, col: 0, x: 4.5, y: 0)),
                KeyboardKnob(index: 1, x: 6.5, y: 0, size: 1, press: KeyboardKey(row: 4, col: 1, x: 6.5, y: 0)),
                KeyboardKnob(index: 2, x: 4.5, y: 1, size: 3)],
        protocolVersion: 12,
        lighting: KeyboardLighting(channel: 1, effectID: 1, brightnessID: 2, speedID: 3, colorID: 4,
                                   effects: [(0, "关闭"), (1, "彩虹"), (2, "呼吸"), (3, "跑马灯"), (4, "常亮"), (5, "循环"), (6, "流星"),
                                             (7, "波浪"), (8, "涟漪"), (9, "星空"), (10, "溪流"), (11, "跟随按键"), (12, "层叠波浪"),
                                             (13, "正弦波"), (14, "彩泉"), (15, "柔和渐隐"), (16, "花园"), (17, "双重效果"),
                                             (18, "峰值回落"), (19, "交叉色彩"), (20, "飘雪")],
                                   brightness: 1...255, speed: 1...5, colorEffects: [4], indicatorOnly: false),
        custom: [KeyboardCustomKey(short: "BKP", name: "备用", hidden: true), KeyboardCustomKey(short: "BKP", name: "备用", hidden: true),
                 KeyboardCustomKey(short: "BKP", name: "备用", hidden: true), KeyboardCustomKey(short: "USB", name: "USB 模式", hidden: true),
                 KeyboardCustomKey(short: "BKP", name: "备用", hidden: true), KeyboardCustomKey(short: "关灯", name: "关闭灯光"),
                 KeyboardCustomKey(short: "开灯", name: "打开灯光"), KeyboardCustomKey(short: "重启", name: "重启键盘", hidden: true),
                 KeyboardCustomKey(short: "清空", name: "清空 EEPROM", hidden: true), KeyboardCustomKey(short: "升级", name: "进入升级模式", hidden: true),
                 KeyboardCustomKey(short: "BKP", name: "备用", hidden: true), KeyboardCustomKey(short: "灯 +", name: "灯光亮度 +"),
                 KeyboardCustomKey(short: "灯 −", name: "灯光亮度 −"), KeyboardCustomKey(short: "触感 +", name: "触感力度 +"),
                 KeyboardCustomKey(short: "触感 −", name: "触感力度 −"), KeyboardCustomKey(short: "触发 +", name: "触发点 +")],
        driverName: "官方配置器：via.yuxibin.top", driverLink: "https://binepad.com/blogs/configurator/bnk16-wr-configurator")
}

/// Lighting values as the board reports them; hue and saturation are 0–255.
struct KeyboardLightingValues: Equatable, Codable {
    var effect = 0
    var brightness = 0
    var speed = 0
    var hue = 0
    var saturation = 255
}

/// One macro step, as QMK stores it: plain text, or a key tap, press, release or delay.
enum MacroStep: Equatable, Hashable {
    case text(String)
    case tap(UInt8), down(UInt8), up(UInt8)
    case delay(Int)
}

/// QMK's dynamic macro encoding: macros end with 0; 0x01 prefixes tap (1), down (2), up (3) + keycode, or delay (4) + digits + '|'.
enum MacroCodec {
    static func decode(_ buffer: [UInt8], count: Int) -> [[MacroStep]] {
        var macros: [[MacroStep]] = []
        var steps: [MacroStep] = [], text = "", i = 0
        func flushText() { if !text.isEmpty { steps.append(.text(text)); text = "" } }
        while i < buffer.count && macros.count < count {
            let byte = buffer[i]
            if byte == 0 { flushText(); macros.append(steps); steps = []; i += 1; continue }
            if byte == 1, i + 2 < buffer.count {
                flushText()
                switch buffer[i + 1] {
                case 1: steps.append(.tap(buffer[i + 2])); i += 3
                case 2: steps.append(.down(buffer[i + 2])); i += 3
                case 3: steps.append(.up(buffer[i + 2])); i += 3
                case 4:
                    var j = i + 2, digits = ""
                    while j < buffer.count, buffer[j] != UInt8(ascii: "|") { digits.append(Character(UnicodeScalar(buffer[j]))); j += 1 }
                    steps.append(.delay(Int(digits) ?? 0)); i = j + 1
                default: i += 2
                }
                continue
            }
            text.append(Character(UnicodeScalar(byte))); i += 1
        }
        while macros.count < count { macros.append([]) }
        return macros
    }
    static func encode(_ macros: [[MacroStep]]) -> [UInt8] {
        var bytes: [UInt8] = []
        for steps in macros {
            for step in steps {
                switch step {
                case .text(let text): bytes += text.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }.map { UInt8($0.value) }
                case .tap(let code): bytes += [1, 1, code]
                case .down(let code): bytes += [1, 2, code]
                case .up(let code): bytes += [1, 3, code]
                case .delay(let ms): bytes += [1, 4] + Array(String(max(0, ms)).utf8) + [UInt8(ascii: "|")]
                }
            }
            bytes.append(0)
        }
        return bytes
    }
}

/// Everything read from one VIA keyboard; `keymap[layer][row * cols + col]`, `encoders[layer][knob]` = (counter-clockwise, clockwise).
struct KeyboardState: Equatable {
    var layers: Int
    var keymap: [[UInt16]]
    var encoders: [[[UInt16]]]
    var macroCount: Int
    var macroBufferSize: Int
    var macros: [[MacroStep]]
    var lighting: KeyboardLightingValues?
    func keycode(_ layer: Int, _ key: KeyboardKey, cols: Int) -> UInt16 {
        keymap.indices.contains(layer) && keymap[layer].indices.contains(key.row * cols + key.col) ? keymap[layer][key.row * cols + key.col] : 0
    }
    var macroBytes: Int { MacroCodec.encode(macros).count }
    var macrosInUse: Int { macros.filter { !$0.isEmpty }.count }
}

/// A USB keyboard on the bus; `model` is set when MacPulse can drive it.
struct WiredKeyboard: Identifiable, Equatable {
    let id: String
    let name: String
    let vendorID: Int
    let productID: Int
    var location = 0
    var model: KeyboardModel? { KeyboardModel.resolve(vendorID: vendorID, productID: productID) }
    static func == (a: WiredKeyboard, b: WiredKeyboard) -> Bool { a.id == b.id && a.name == b.name }
}

/// QMK keycode names, with Mac symbols for modifiers.
enum Keycode {
    struct Entry: Identifiable, Hashable {
        let code: UInt16
        let short: String
        let name: String
        var id: UInt16 { code }
    }
    static let basic: [Entry] = {
        var list: [Entry] = []
        for (i, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { list.append(Entry(code: UInt16(0x04 + i), short: String(letter), name: "字母 \(letter)")) }
        for (i, digit) in "1234567890".enumerated() { list.append(Entry(code: UInt16(0x1E + i), short: String(digit), name: "数字 \(digit)")) }
        list += [Entry(code: 0x28, short: "⏎", name: "回车 Return"), Entry(code: 0x29, short: "Esc", name: "Esc"), Entry(code: 0x2A, short: "⌫", name: "删除 Backspace"),
                 Entry(code: 0x2B, short: "⇥", name: "Tab"), Entry(code: 0x2C, short: "空格", name: "空格"), Entry(code: 0x2D, short: "-", name: "减号 -"),
                 Entry(code: 0x2E, short: "=", name: "等号 ="), Entry(code: 0x2F, short: "[", name: "左方括号 ["), Entry(code: 0x30, short: "]", name: "右方括号 ]"),
                 Entry(code: 0x31, short: "\\", name: "反斜杠 \\"), Entry(code: 0x33, short: ";", name: "分号 ;"), Entry(code: 0x34, short: "'", name: "引号 '"),
                 Entry(code: 0x35, short: "`", name: "反引号 `"), Entry(code: 0x36, short: ",", name: "逗号 ,"), Entry(code: 0x37, short: ".", name: "句号 ."),
                 Entry(code: 0x38, short: "/", name: "斜杠 /"), Entry(code: 0x39, short: "⇪", name: "大写锁定 Caps Lock")]
        for i in 0..<12 { list.append(Entry(code: UInt16(0x3A + i), short: "F\(i + 1)", name: "F\(i + 1)")) }
        for i in 0..<12 { list.append(Entry(code: UInt16(0x68 + i), short: "F\(i + 13)", name: "F\(i + 13)")) }
        list += [Entry(code: 0x46, short: "PrtSc", name: "截屏 Print Screen"), Entry(code: 0x47, short: "ScrLk", name: "Scroll Lock"), Entry(code: 0x48, short: "Pause", name: "Pause"),
                 Entry(code: 0x49, short: "Ins", name: "插入 Insert"), Entry(code: 0x4A, short: "Home", name: "Home"), Entry(code: 0x4B, short: "PgUp", name: "向上翻页 Page Up"),
                 Entry(code: 0x4C, short: "⌦", name: "向前删除 Delete"), Entry(code: 0x4D, short: "End", name: "End"), Entry(code: 0x4E, short: "PgDn", name: "向下翻页 Page Down"),
                 Entry(code: 0x4F, short: "→", name: "右"), Entry(code: 0x50, short: "←", name: "左"), Entry(code: 0x51, short: "↓", name: "下"), Entry(code: 0x52, short: "↑", name: "上"),
                 Entry(code: 0x65, short: "菜单", name: "应用菜单")]
        return list
    }()
    static let numpad: [Entry] = {
        var list = [Entry(code: 0x53, short: "Num", name: "Num Lock"), Entry(code: 0x54, short: "/", name: "小键盘 /"), Entry(code: 0x55, short: "*", name: "小键盘 *"),
                    Entry(code: 0x56, short: "-", name: "小键盘 -"), Entry(code: 0x57, short: "+", name: "小键盘 +"), Entry(code: 0x58, short: "Enter", name: "小键盘 Enter")]
        for i in 1...9 { list.append(Entry(code: UInt16(0x58 + i), short: "\(i)", name: "小键盘 \(i)")) }
        list += [Entry(code: 0x62, short: "0", name: "小键盘 0"), Entry(code: 0x63, short: ".", name: "小键盘 ."), Entry(code: 0x67, short: "=", name: "小键盘 =")]
        return list
    }()
    static let modifiers: [Entry] = [
        Entry(code: 0xE0, short: "⌃", name: "左 Control"), Entry(code: 0xE1, short: "⇧", name: "左 Shift"), Entry(code: 0xE2, short: "⌥", name: "左 Option"),
        Entry(code: 0xE3, short: "⌘", name: "左 Command"), Entry(code: 0xE4, short: "⌃", name: "右 Control"), Entry(code: 0xE5, short: "⇧", name: "右 Shift"),
        Entry(code: 0xE6, short: "⌥", name: "右 Option"), Entry(code: 0xE7, short: "⌘", name: "右 Command"),
    ]
    static let media: [Entry] = [
        Entry(code: 0xA8, short: "静音", name: "静音"), Entry(code: 0xAA, short: "音量 −", name: "音量减"), Entry(code: 0xA9, short: "音量 +", name: "音量加"),
        Entry(code: 0xAE, short: "播放", name: "播放 / 暂停"), Entry(code: 0xAC, short: "上一首", name: "上一首"), Entry(code: 0xAB, short: "下一首", name: "下一首"),
        Entry(code: 0xBC, short: "快退", name: "快退"), Entry(code: 0xBB, short: "快进", name: "快进"), Entry(code: 0xAD, short: "停止", name: "停止播放"),
        Entry(code: 0xBE, short: "亮度 −", name: "屏幕亮度减"), Entry(code: 0xBD, short: "亮度 +", name: "屏幕亮度加"),
        Entry(code: 0xC1, short: "调度", name: "调度中心（Mission Control）"), Entry(code: 0xC2, short: "启动台", name: "启动台（Launchpad）"),
        Entry(code: 0xB2, short: "计算器", name: "计算器"), Entry(code: 0xB1, short: "邮件", name: "邮件"), Entry(code: 0xB0, short: "推出", name: "推出"),
        Entry(code: 0xA6, short: "睡眠", name: "系统睡眠"),
        Entry(code: 0xCD, short: "鼠标↑", name: "鼠标上移"), Entry(code: 0xCE, short: "鼠标↓", name: "鼠标下移"), Entry(code: 0xCF, short: "鼠标←", name: "鼠标左移"),
        Entry(code: 0xD0, short: "鼠标→", name: "鼠标右移"), Entry(code: 0xD1, short: "左键", name: "鼠标左键"), Entry(code: 0xD2, short: "右键", name: "鼠标右键"),
        Entry(code: 0xD3, short: "中键", name: "鼠标中键"), Entry(code: 0xD9, short: "滚轮↑", name: "滚轮向上"), Entry(code: 0xDA, short: "滚轮↓", name: "滚轮向下"),
    ]
    static let lighting: [Entry] = [
        Entry(code: 0x7820, short: "灯开关", name: "灯光开关"), Entry(code: 0x7821, short: "灯效 →", name: "下一个灯效"), Entry(code: 0x7822, short: "灯效 ←", name: "上一个灯效"),
        Entry(code: 0x7823, short: "色相 +", name: "色相加"), Entry(code: 0x7824, short: "色相 −", name: "色相减"), Entry(code: 0x7825, short: "饱和 +", name: "饱和度加"),
        Entry(code: 0x7826, short: "饱和 −", name: "饱和度减"), Entry(code: 0x7827, short: "灯亮 +", name: "灯光亮度加"), Entry(code: 0x7828, short: "灯亮 −", name: "灯光亮度减"),
        Entry(code: 0x7829, short: "灯速 +", name: "灯效速度加"), Entry(code: 0x782A, short: "灯速 −", name: "灯效速度减"),
    ]
    /// Layer functions, in the order the picker shows them.
    static let layerKinds: [(base: UInt16, short: String, name: String)] = [
        (0x5220, "MO", "按住时切到该层"), (0x5260, "TG", "开关该层"), (0x5200, "TO", "切换到该层"),
        (0x52C0, "TT", "按住临时、连按切换"), (0x5280, "OSL", "下一个键用该层"), (0x5240, "DF", "设为默认层"),
    ]
    static let modBits: [(bit: UInt16, symbol: String, name: String)] = [(0x01, "⌃", "Control"), (0x02, "⇧", "Shift"), (0x04, "⌥", "Option"), (0x08, "⌘", "Command")]
    private static let table: [UInt16: Entry] = Dictionary((basic + numpad + modifiers + media + lighting).map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })

    static func modSymbols(_ mods: UInt16) -> String {
        (mods & 0x10 != 0 ? "右" : "") + modBits.filter { mods & $0.bit != 0 }.map(\.symbol).joined()
    }
    /// Short label for a keycap, and a full name for help text and the picker.
    static func describe(_ code: UInt16, model: KeyboardModel) -> (short: String, name: String) {
        if code == 0 { return ("", "无") }
        if code == 1 { return ("▽", "透明：使用下层的键") }
        if let entry = table[code] { return (entry.short, entry.name) }
        if code >= model.macroBase && code < model.macroBase + 0x80 { let n = Int(code - model.macroBase); return ("M\(n)", "宏 \(n)") }
        if code >= model.customBase && code < model.customBase + 0x40 {
            let n = Int(code - model.customBase)
            if model.custom.indices.contains(n) { return (model.custom[n].short, model.custom[n].name) }
            return ("自定 \(n)", "自定义键 \(n)")
        }
        switch code {
        case 0x0100...0x1FFF:
            let key = describe(code & 0xFF, model: model)
            return (modSymbols(code >> 8 & 0x1F) + key.short, modSymbols(code >> 8 & 0x1F) + " + " + key.name)
        case 0x2000...0x3FFF:
            let key = describe(code & 0xFF, model: model), mods = modSymbols(code >> 8 & 0x1F)
            return ("\(mods)\n\(key.short)", "按住 \(mods)，点按 \(key.name)")
        case 0x4000...0x4FFF:
            let key = describe(code & 0xFF, model: model), layer = Int(code >> 8 & 0x0F)
            return ("L\(layer)\n\(key.short)", "按住切到层 \(layer)，点按 \(key.name)")
        case 0x5200...0x52DF:
            let kind = layerKinds.filter { code >= $0.base }.max { $0.base < $1.base }!
            if kind.base == 0x5280, code >= 0x52A0 { return ("OSM\n\(modSymbols(code & 0x1F))", "单次修饰 \(modSymbols(code & 0x1F))") }
            let layer = Int(code - kind.base)
            return ("\(kind.short) \(layer)", "\(kind.name)：层 \(layer)")
        case 0x7C00: return ("Boot", "进入刷机模式")
        case 0x7C03: return ("清 EE", "清空 EEPROM")
        default: return (String(format: "%04X", code), String(format: "键码 0x%04X", code))
        }
    }
    /// Keys that must not be assigned from MacPulse: they reboot, flash or wipe the board.
    static func blocked(_ code: UInt16, model: KeyboardModel) -> Bool {
        if code == 0x7C00 || code == 0x7C01 || code == 0x7C03 { return true }
        let n = Int(code) - Int(model.customBase)
        return model.custom.indices.contains(n) && model.custom[n].hidden
    }

    /// macOS virtual key codes to HID usages, for "press a key to assign".
    static let fromMac: [UInt16: UInt16] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F,
        0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B,
        0x10: 0x1C, 0x06: 0x1D, 0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34,
        0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38, 0x39: 0x39, 0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40,
        0x64: 0x41, 0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45, 0x72: 0x49, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E, 0x7C: 0x4F,
        0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52, 0x47: 0x53, 0x4B: 0x54, 0x43: 0x55, 0x4E: 0x56, 0x45: 0x57, 0x4C: 0x58, 0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B,
        0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, 0x59: 0x5F, 0x5B: 0x60, 0x5C: 0x61, 0x52: 0x62, 0x41: 0x63, 0x51: 0x67,
        0x3B: 0xE0, 0x38: 0xE1, 0x3A: 0xE2, 0x37: 0xE3, 0x3E: 0xE4, 0x3C: 0xE5, 0x3D: 0xE6, 0x36: 0xE7,
    ]
}

/// Owns wired keyboards for the settings page and the panel: the plugged-in list, what each VIA board reported,
/// writes with read-back, lighting previews and backups. Device I/O runs on DeviceIO.queue, state lives on main.
final class KeyboardCenter: ObservableObject {
    @Published private(set) var keyboards: [WiredKeyboard] = []
    @Published private(set) var states: [String: KeyboardState] = [:]
    /// Why a supported keyboard has no state (channel busy, unexpected firmware…).
    @Published private(set) var problems: [String: String] = [:]
    /// Panel lighting changes being previewed, not yet saved to the board.
    @Published private(set) var lightingDrafts: [String: KeyboardLightingValues] = [:]
    @Published private(set) var busy = false
    @Published private(set) var backupCount = 0
    @Published var message = ""
    @Published var failed = false
    private var readAt: Date?
    /// `--keyboard-preview` shows the boards' recorded data without touching any device.
    private let preview = CommandLine.arguments.contains("--keyboard-preview")
    private var watcher: WiredKeyboardWatcher?
    // Only touched on DeviceIO.queue.
    private var channels: [String: VIAChannel] = [:]
    private var backedUp: Set<String> = []
    private var shownLighting: [String: KeyboardLightingValues] = [:]
    private var pendingPreview: [String: (WiredKeyboard, KeyboardLightingValues)] = [:]
    private var previewScheduled = false

    init() {
        if preview { loadPreview(); return }
        let watcher = WiredKeyboardWatcher()
        watcher.onChange = { [weak self] list in self?.devicesChanged(list) }
        self.watcher = watcher
    }

    func state(_ id: String) -> KeyboardState? { states[id] }
    func keyboard(_ id: String) -> WiredKeyboard? { keyboards.first { $0.id == id } }

    // MARK: Reading

    func refreshIfStale(_ age: TimeInterval) {
        if readAt.map({ Date().timeIntervalSince($0) > age }) ?? true { refresh() }
    }
    func refresh(_ ids: Set<String>? = nil) {
        guard !preview, !busy else { return }
        let targets = keyboards.filter { $0.model != nil && (ids?.contains($0.id) ?? true) }
        readAt = Date()
        guard !targets.isEmpty else { return }
        busy = true
        DeviceIO.queue.async { [weak self] in
            guard let self else { return }
            var states: [String: KeyboardState] = [:], problems: [String: String] = [:]
            for keyboard in targets {
                do {
                    let channel = try self.channel(keyboard)
                    let state = try channel.withOpen { try VIAKeyboard.read(channel, model: keyboard.model!) }
                    states[keyboard.id] = state
                    self.shownLighting[keyboard.id] = state.lighting
                } catch {
                    problems[keyboard.id] = error.localizedDescription
                    self.channels[keyboard.id] = nil
                }
            }
            DispatchQueue.main.async {
                for keyboard in targets { self.states[keyboard.id] = states[keyboard.id]; self.problems[keyboard.id] = problems[keyboard.id] }
                self.busy = false
            }
        }
    }

    /// The plugged-in list changed: drop what left, and read new boards if anything has asked for keyboards yet.
    private func devicesChanged(_ list: [WiredKeyboard]) {
        let ids = Set(list.map(\.id))
        for id in channels.keys where !ids.contains(id) { channels[id] = nil; shownLighting[id] = nil }
        DispatchQueue.main.async { [self] in
            let fresh = Set(list.filter { $0.model != nil && states[$0.id] == nil }.map(\.id))
            keyboards = list
            for id in states.keys where !ids.contains(id) { states[id] = nil; lightingDrafts[id] = nil }
            for id in problems.keys where !ids.contains(id) { problems[id] = nil }
            // A snapshot renders after a fixed wait, so it reads boards as soon as they appear.
            if readAt != nil || CommandLine.arguments.contains("--snapshot"), !fresh.isEmpty { refresh(fresh) }
        }
    }

    /// On DeviceIO.queue: the board's VIA interface, kept between commands until it is unplugged.
    private func channel(_ keyboard: WiredKeyboard) throws -> VIAChannel {
        if let channel = channels[keyboard.id] { return channel }
        guard let channel = VIAChannel.find(vendorID: keyboard.vendorID, productID: keyboard.productID, location: keyboard.location) else { throw VIAError.openFailed }
        channels[keyboard.id] = channel
        return channel
    }

    // MARK: Writing

    /// Backs the board up the first time this session writes to it, writes only what changed, then reads it all back.
    func apply(_ id: String, _ draft: KeyboardState) {
        guard !busy, let keyboard = keyboard(id), let model = keyboard.model, let old = states[id] else { return }
        if preview { report("预览模式：没有写入键盘", failed: true); return }
        busy = true
        DeviceIO.queue.async { [weak self] in
            guard let self else { return }
            let result = Result { () throws -> (KeyboardState, Bool) in
                let channel = try self.channel(keyboard)
                var backedUp = false
                if !self.backedUp.contains(id) {
                    _ = try KeyboardBackup.save(KeyboardBackup(model: model, state: old), model: model)
                    self.backedUp.insert(id); backedUp = true
                }
                let readBack = try channel.withOpen { try VIAKeyboard.apply(channel, model: model, draft, over: old) }
                self.shownLighting[id] = readBack.lighting
                return (readBack, backedUp)
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let (readBack, backedUp)):
                    self.states[id] = readBack
                    self.lightingDrafts[id] = nil
                    if backedUp { self.backupCount += 1 }
                    self.report("已写入键盘并读回校验" + (backedUp ? "；写入前已自动备份" : ""), failed: false)
                case .failure(let error):
                    self.report(error.localizedDescription, failed: true)
                    self.refresh([id])
                }
            }
        }
    }

    /// Shows lighting on the board without saving it; rapid slider changes collapse into one write.
    func previewLighting(_ id: String, _ values: KeyboardLightingValues) {
        guard !preview, let keyboard = keyboard(id), keyboard.model?.lighting != nil else { return }
        DeviceIO.queue.async { [weak self] in
            guard let self else { return }
            self.pendingPreview[id] = (keyboard, values)
            guard !self.previewScheduled else { return }
            self.previewScheduled = true
            DeviceIO.queue.asyncAfter(deadline: .now() + 0.06) { self.flushPreviews() }
        }
    }
    private func flushPreviews() {
        previewScheduled = false
        let pending = pendingPreview; pendingPreview = [:]
        for (id, (keyboard, values)) in pending {
            do {
                let channel = try channel(keyboard)
                try channel.withOpen { try VIAKeyboard.setLighting(channel, model: keyboard.model!, values, over: shownLighting[id], save: false) }
                shownLighting[id] = values
            } catch { channels[id] = nil }
        }
    }

    /// What the panel shows: the previewed values while there are some, else what the board reported.
    func lighting(_ id: String) -> KeyboardLightingValues? { lightingDrafts[id] ?? states[id]?.lighting }
    func setLightingDraft(_ id: String, _ values: KeyboardLightingValues) {
        lightingDrafts[id] = values == states[id]?.lighting ? nil : values
        previewLighting(id, values)
    }
    func revertLighting(_ id: String) {
        lightingDrafts[id] = nil
        if let saved = states[id]?.lighting { previewLighting(id, saved) }
    }
    /// Saves the panel's previewed lighting: the same write and read-back as the settings page.
    func saveLighting(_ id: String) {
        guard var draft = states[id], let values = lightingDrafts[id] else { return }
        draft.lighting = values
        apply(id, draft)
    }

    // MARK: Backups

    func backups(_ id: String) -> [URL] {
        _ = backupCount
        return keyboard(id)?.model.map(KeyboardBackup.list) ?? []
    }
    /// Writes a backup's keymap, knobs, macros and lighting back, through the same checked path as an edit.
    func restore(_ id: String, from url: URL) {
        guard let saved = states[id] else { return }
        do {
            let backup = try KeyboardBackup.load(url)
            guard backup.fits(saved) else { report("这份备份的层数或宏容量与键盘当前不一致，没有恢复", failed: true); return }
            apply(id, backup.state)
        } catch { report("读不出这份备份：\(error.localizedDescription)", failed: true) }
    }

    private func report(_ text: String, failed: Bool) {
        message = text; self.failed = failed
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.message == text { self?.message = "" } }
    }

    /// What the two boards on the development Mac reported over VIA (read-only), so the editor has real keymaps to show.
    private func loadPreview() {
        keyboards = [WiredKeyboard(id: "usb-b710-b710", name: "BUFF67v3r2", vendorID: 0xB710, productID: 0xB710),
                     WiredKeyboard(id: "usb-1a86-fc16", name: "BNK 16", vendorID: 0x1A86, productID: 0xFC16)]
        let t: UInt16 = 1
        let buffBase: [UInt16] = [0x29, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E, 0x2A, 0x4A,
                                  0x2B, 0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C, 0x12, 0x13, 0x2F, 0x30, 0x31, 0x4D,
                                  0x39, 0x04, 0x16, 0x07, 0x09, 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x33, 0x34, 0, 0x28, 0x4B,
                                  0xE1, 0x1D, 0x1B, 0x06, 0x19, 0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0, 0xE5, 0x52, 0x4E,
                                  0xE0, 0xE3, 0xE2, 0, 0, 0, 0x2C, 0xE6, 0, 0, 0, 0x5221, 0x50, 0x51, 0x4F]
        var buffFn = [UInt16](repeating: t, count: 75)
        buffFn[0] = 0x35; for i in 1...12 { buffFn[i] = UInt16(0x39 + i) }; buffFn[13] = 0x4C
        buffFn[32...35] = [0x7823, 0x7824, 0x7825, 0x7826]; buffFn[46...50] = [0x7820, 0x7821, 0x7822, 0x7827, 0x7828]
        buffFn[61] = 0x7F00
        for i in [42, 56, 63, 64, 65, 68, 69, 70] { buffFn[i] = 0 }
        var buffEmpty = [UInt16](repeating: t, count: 75)
        for i in [42, 56, 63, 64, 65, 68, 69, 70] { buffEmpty[i] = 0 }
        states["usb-b710-b710"] = KeyboardState(layers: 4, keymap: [buffBase, buffFn, buffEmpty, buffEmpty], encoders: Array(repeating: [], count: 4),
                                                macroCount: 16, macroBufferSize: 386, macros: Array(repeating: [], count: 16),
                                                lighting: KeyboardLightingValues(effect: 9, brightness: 255, speed: 0, hue: 0, saturation: 255))
        let bnkBase: [UInt16] = [0x5F, 0x60, 0x61, 0x54, 0xF1, 0x5C, 0x5D, 0x5E, 0x55, 0xF2, 0x59, 0x5A, 0x5B, 0x56, 0,
                                 0x62, 0x63, 0x58, 0x57, 0, 0xAE, 0xA8, 0, 0, 0]
        var bnkLayers = [bnkBase]
        var bnkLight = [UInt16](repeating: t, count: 25); bnkLight[20] = 0x7E06; bnkLight[21] = 0x7E05
        bnkLayers.append(bnkLight)
        bnkLayers += Array(repeating: [UInt16](repeating: t, count: 25), count: 8)
        let media: [[UInt16]] = [[0xAC, 0xAB], [0x4B, 0x4E], [0xAA, 0xA9]]
        let encoders: [[[UInt16]]] = [[[0xBE, 0xBD], [0xAA, 0xA9], [0x50, 0x4F]], media, media, media] + Array(repeating: [[0, 0], [0, 0], [0, 0]], count: 6)
        states["usb-1a86-fc16"] = KeyboardState(layers: 10, keymap: bnkLayers, encoders: encoders, macroCount: 18, macroBufferSize: 1008,
                                                macros: [[.text("Hello"), .tap(0x28)], [.down(0xE3), .tap(0x06), .up(0xE3)]] + Array(repeating: [], count: 16),
                                                lighting: KeyboardLightingValues(effect: 4, brightness: 255, speed: 5, hue: 251, saturation: 1))
    }
}
