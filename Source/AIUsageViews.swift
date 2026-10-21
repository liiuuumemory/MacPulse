import SwiftUI
import AppKit

private typealias AIViewState<Value> = SwiftUI.State<Value>

struct TokenHeatmap: View {
    let activity: TokenActivity
    let color: Color
    var compact = true
    @AIViewState private var selected: Date?
    private var calendar: Calendar { .current }
    private var dates: [Date] {
        let end = calendar.startOfDay(for: Date())
        // Whole weeks, with the current week ending at the right edge.
        let weekday = (calendar.component(.weekday, from: end) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -weekday, to: end)!
        let first = calendar.date(byAdding: .day, value: -25 * 7, to: monday)!
        return (0..<182).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    // 182 cells each label twice per render; never build a DateFormatter per cell.
    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M/d"; return f }()
    private func label(_ date: Date, _ value: Double) -> String {
        Self.dayFormatter.string(from: date) + " · " + UsageFormat.tokens(value) + " Token"
    }
    var body: some View {
        let allDates = dates
        let values = Dictionary(uniqueKeysWithValues: activity.days.map { ($0.date, $0.tokens) })
        let maximum = max(1, activity.days.map(\.tokens).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(selected.map { label($0, values[$0] ?? 0) } ?? "Token 活动 · 近半年")
                Spacer(minLength: 4)
                Text(activity.source.replacingOccurrences(of: "本机日志", with: "本机记录"))
            }.font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { geometry in
                let cell = max(3, (geometry.size.width - 25 * 2) / 26)
                HStack(alignment: .top, spacing: 2) {
                    ForEach(0..<26, id: \.self) { week in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { day in
                                let date = allDates[week * 7 + day]
                                let value = values[date] ?? 0
                                let future = date > calendar.startOfDay(for: Date())
                                let opacity = value > 0 ? 0.22 + 0.78 * log1p(value) / log1p(maximum) : 0
                                Button { selected = date } label: {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(future ? Color.clear : value > 0 ? color.opacity(opacity) : Color.secondary.opacity(0.09))
                                        .overlay { if selected == date { RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 1) } }
                                        .frame(width: cell, height: compact ? 6 : 12)
                                }.buttonStyle(.plain).disabled(future)
                                    .help(label(date, value)).accessibilityLabel(label(date, value))
                            }
                        }
                    }
                }
            }.frame(height: compact ? 54 : 96)
        }
    }
}

struct QuotaBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(fraction < 0.15 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }.frame(height: 4).accessibilityLabel("剩余额度")
            .accessibilityValue(String(format: "%.0f%%", max(0, min(1, fraction)) * 100))
    }
}

struct AIQuotaSummary: View {
    @ObservedObject var usage: AIUsageMonitor
    var compact = true
    private var provider: AIProvider { usage.selected }
    var body: some View {
        // Countdowns advance on their own, not only when a new sample arrives.
        TimelineView(.periodic(from: .now, by: 30)) { context in summary(now: context.date) }
    }
    @ViewBuilder private func summary(now: Date) -> some View {
        let custom = usage.budget(provider)
        let account = usage.accounts[provider] ?? AccountQuota()
        let service = usage.status[provider]
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            HStack(spacing: 6) {
                Text(custom.enabled ? "自定义剩余额度" : "账户剩余额度")
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
                if !custom.enabled && account.stale && account.hasData {
                    Text("旧数据").font(.caption2).foregroundStyle(.orange)
                }
                if custom.enabled {
                    Text(UsageFormat.amount(custom.remaining(at: now), unit: custom.unit))
                        .font(.system(size: compact ? 12 : 18)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                } else if let balance = account.balance {
                    Text(UsageFormat.amount(balance, unit: account.unit))
                        .font(.system(size: compact ? 12 : 18)).monospacedDigit().lineLimit(1)
                } else if account.unlimited { Text("不限额").font(.callout) }
                else if !account.hasData { Text("未获取").font(.caption).foregroundStyle(.secondary) }
            }
            if custom.enabled {
                QuotaBar(fraction: custom.remaining(at: now) / custom.total)
                HStack(spacing: 6) {
                    Text("已用 " + UsageFormat.amount(custom.effectiveUsed(at: now), unit: custom.unit))
                    Spacer(minLength: 0)
                    Text(UsageFormat.countdown(custom.resetAt(at: now), now: now)).help(UsageFormat.reset(custom.resetAt(at: now)))
                }.font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary).lineLimit(1)
            } else if !account.windows.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(account.windows.prefix(compact ? 2 : 4))) { window in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(window.title)
                                Text(window.remaining(at: now).map { String(format: "剩 %.0f%%", $0) } ?? "待更新").monospacedDigit()
                            }.font(.system(size: compact ? 10 : 12)).lineLimit(1)
                            if let remaining = window.remaining(at: now) { QuotaBar(fraction: remaining / 100) }
                            Text(window.resetAt == nil ? "重置时间未提供" : UsageFormat.countdown(window.resetAt, now: now))
                                .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary).lineLimit(1)
                                .help(window.resetAt == nil ? "" : UsageFormat.reset(window.resetAt))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if !account.hasData {
                Text(usage.refreshing && account.error == nil ? "正在查询…" : compact ? "可在设置中连接账户或填写自定义额度" : account.error ?? "等待首次查询")
                    .font(.system(size: compact ? 9 : 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let service, service.degraded {
                Text("\(provider.title) 服务状态：\(service.label)" + (compact ? "" : "（\(service.description)）"))
                    .font(.system(size: compact ? 9 : 11)).foregroundStyle(.orange).lineLimit(compact ? 1 : nil)
                    .help(service.description)
            }
            if !compact && !custom.enabled {
                Text(account.account).font(.caption).foregroundStyle(.secondary)
                if let date = account.fetchedAt { Text("更新于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                if account.hasData, let error = account.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }.frame(maxWidth: compact ? .infinity : 420, alignment: .leading)
    }
}

struct AIUsagePanel: View {
    @ObservedObject var usage: AIUsageMonitor
    var openSettings: () -> Void
    private var activity: TokenActivity { usage.activity[usage.selected] ?? TokenActivity() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("AI 用量").font(.callout.weight(.medium))
                Picker("AI 服务", selection: $usage.selected) {
                    ForEach(AIProvider.allCases) { provider in Text(provider.title).tag(provider) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                if let service = usage.status[usage.selected], service.degraded {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("\(usage.selected.title) 服务状态：\(service.label)（\(service.description)）")
                        .accessibilityLabel("\(usage.selected.title) 服务状态：\(service.label)")
                }
                Spacer(minLength: 0)
                Button { usage.preferencesTab = "ai"; openSettings() } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help("用量详情与额度设置").accessibilityLabel("用量详情与额度设置")
            }
            HStack(spacing: 12) {
                statistic("今日", activity.today, cost: activity.todayCost)
                statistic("近 7 天", activity.week, cost: activity.weekCost)
                statistic("累计", activity.total, cost: activity.totalCost)
            }.help("费用按 API 公开标价估算，不等同于账单")
            TokenHeatmap(activity: activity, color: usage.selected == .codex ? .purple : .orange)
            AIQuotaSummary(usage: usage)
        }
    }
    private func statistic(_ title: String, _ value: Double, cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(activity.loaded ? UsageFormat.tokens(value) : "—").font(.system(size: 12)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
            Text(activity.loaded ? "≈ " + UsageFormat.amount(cost, unit: "USD") : " ").font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1)
        }.frame(width: (PanelLayout.width - 48) / 3, alignment: .leading)
    }
}

struct AIUsageSettingsView: View {
    @ObservedObject var usage: AIUsageMonitor
    @AIViewState private var enabled = false
    @AIViewState private var total = "100"
    @AIViewState private var used = "0"
    @AIViewState private var unit = "USD"
    @AIViewState private var period = "none"
    @AIViewState private var message = ""
    @AIViewState private var detailsExpanded = true
    private var activity: TokenActivity { usage.activity[usage.selected] ?? TokenActivity() }
    private var draft: CustomQuota? {
        guard let limit = Double(total.trimmingCharacters(in: .whitespaces)), let spent = Double(used.trimmingCharacters(in: .whitespaces)) else { return nil }
        let value = CustomQuota(enabled: enabled, total: limit, used: spent, unit: unit, period: period, updatedAt: Date())
        return value.valid ? value : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI 用量与额度").font(.title3.weight(.medium))
                Spacer()
                Button { usage.refresh() } label: { Label(usage.refreshing ? "更新中" : "刷新", systemImage: "arrow.clockwise") }
                    .disabled(usage.refreshing)
            }
            Picker("AI 服务", selection: $usage.selected) {
                ForEach(AIProvider.allCases) { provider in Text(provider.title).tag(provider) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 240, alignment: .leading)
            PreferenceCard(title: "额度显示") {
                AIQuotaSummary(usage: usage, compact: false)
                HStack(spacing: 8) {
                    if usage.selected == .claude {
                        Button("连接本机 Claude Code") { usage.refresh(allowClaudePrompt: true) }.disabled(usage.refreshing)
                    }
                    Button("打开账户用量页面") {
                        let account = usage.accounts[usage.selected]
                        let fallback = URL(string: usage.selected == .codex ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage")!
                        NSWorkspace.shared.open(account?.website ?? fallback)
                    }
                }
                Text("自动额度每 5 分钟刷新。读取不到时保留错误提示，已有数据会标记为旧数据。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("同时检查服务状态页（status.openai.com / status.claude.com，不发送任何本机数据）", isOn: $usage.checkStatus)
                    .toggleStyle(.checkbox).font(.caption)
            }
            PreferenceCard(title: usage.selected.title + " 自定义额度") {
                Toggle("使用自定义额度", isOn: $enabled).toggleStyle(.checkbox)
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "总额度") { TextField("例如 100", text: $total).textFieldStyle(.roundedBorder) }
                    PreferenceField(title: "已用额度") { TextField("例如 24", text: $used).textFieldStyle(.roundedBorder) }
                }
                HStack(alignment: .top, spacing: 16) {
                    PreferenceField(title: "单位") {
                        Picker("单位", selection: $unit) {
                            Text("美元 USD").tag("USD"); Text("人民币 CNY").tag("CNY")
                            Text("Token").tag("Token"); Text("次数").tag("次"); Text("百分比 %").tag("%")
                        }
                    }
                    PreferenceField(title: "重置周期") {
                        Picker("重置周期", selection: $period) {
                            Text("不自动重置").tag("none"); Text("每天零点").tag("day")
                            Text("每周一零点").tag("week"); Text("每月 1 日").tag("month")
                        }
                    }
                }
                if let draft {
                    HStack(spacing: 8) {
                        Text("剩余").foregroundStyle(.secondary)
                        Text(UsageFormat.amount(draft.remaining(), unit: draft.unit)).monospacedDigit()
                    }.font(.callout)
                } else { Text("请填写大于 0 的总额度和不小于 0 的已用额度。").font(.caption).foregroundStyle(.orange) }
                HStack(spacing: 8) {
                    Button("保存额度") {
                        if let draft { usage.save(draft, provider: usage.selected); message = "已保存，菜单栏总览同步更新" }
                    }.disabled(draft == nil)
                    Button("已用归零") { used = "0"; if let draft { usage.save(draft, provider: usage.selected); message = "已用额度已归零" } }.disabled(draft == nil)
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                Text("自定义额度为手动记录，不会自动扣减。到所选周期时，仅将已用额度归零；周期按这台 Mac 的时区计算。关闭后显示自动查询结果。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("用量明细与数据来源", isExpanded: $detailsExpanded) { activityDetails.padding(.top, 10) }
        }.controlSize(.small)
            .onAppear { loadDraft() }
            .onChange(of: usage.selected) { loadDraft() }
    }
    private var activityDetails: some View {
        PreferenceCard(title: usage.selected.title + " 使用情况") {
                Toggle("优先读取 CC Switch 用量记录", isOn: $usage.preferCCSwitch).toggleStyle(.checkbox)
                Text(activity.source.hasPrefix("CC Switch")
                     ? "当前来源：CC Switch（~/.cc-switch，只读，仅查询用量表）" + (activity.latest.map { " · 最近记录 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                     : "当前来源：本机会话日志" + (usage.preferCCSwitch ? "（未找到可读取的 CC Switch 记录）" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let note = activity.note { Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Toggle("通过 iCloud 云盘汇总多台 Mac", isOn: $usage.syncEnabled).toggleStyle(.checkbox)
                if usage.syncEnabled {
                    Text(usage.syncMessage.isEmpty ? "仅同步按天汇总的 Token 数与估算费用到“iCloud 云盘/MacPulse”，不含会话内容。其他 Mac 开启同一选项后自动合并；模型明细只含本机。" : usage.syncMessage)
                        .font(.caption).foregroundStyle(usage.syncMessage.isEmpty ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
                    ForEach(usage.peers, id: \.id) { peer in
                        let days = peer.providers[usage.selected.rawValue] ?? []
                        HStack(spacing: 10) {
                            Image(systemName: "laptopcomputer")
                            Text(peer.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(UsageFormat.tokens(days.reduce(0) { $0 + $1.tokens }) + " Token · ≈ " + UsageFormat.amount(days.reduce(0) { $0 + $1.cost }, unit: "USD"))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text("更新于 " + peer.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }
                HStack(spacing: 20) {
                    field("今日 Token", activity.today, cost: activity.todayCost)
                    field("近 7 天", activity.week, cost: activity.weekCost)
                    field("累计", activity.total, cost: activity.totalCost)
                }
                TokenHeatmap(activity: activity, color: usage.selected == .codex ? .purple : .orange, compact: false)
                if !activity.models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("按模型").font(.callout.weight(.medium))
                        ForEach(activity.models) { model in
                            HStack(spacing: 10) {
                                Text(model.model).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(model.requests) 次 · " + UsageFormat.tokens(model.tokens) + " Token").monospacedDigit().foregroundStyle(.secondary)
                                Text(model.cost.map { "≈ " + UsageFormat.amount($0, unit: "USD") } ?? "无标价").monospacedDigit()
                                    .frame(width: 96, alignment: .trailing)
                            }.font(.callout)
                        }
                    }
                }
                Text(activity.source.hasPrefix("CC Switch")
                     ? "Token 与费用取自 CC Switch 的去重记录和价格表（含已压缩会话与历史汇总）。订阅套餐不按 Token 计费，金额不等同于账单；未定价的模型显示“无标价”。"
                     : "包含输入、输出和缓存 Token；仅统计此 Mac 留存的会话记录。费用按 \(ModelPricing.updated) 的 API 公开标价估算，区分缓存读写价格；订阅套餐不按 Token 计费，金额不等同于账单。未列入价格表的模型显示“无标价”。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = activity.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
    }
    private func field(_ title: String, _ value: Double, cost: Double) -> some View {
        PreferenceField(title: title) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.loaded ? UsageFormat.tokens(value) : "—").font(.title3).monospacedDigit()
                Text(activity.loaded ? "≈ " + UsageFormat.amount(cost, unit: "USD") : " ").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
    private func loadDraft() {
        let value = usage.budget(usage.selected)
        enabled = value.enabled; total = String(format: "%.12g", value.total)
        used = String(format: "%.12g", value.effectiveUsed()); unit = value.unit; period = value.period; message = ""
    }
}
