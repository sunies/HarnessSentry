import AppKit
import HarnessSentryCore
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: DashboardNavigation
    @StateObject private var viewState = DashboardViewState()

    enum Section: String, CaseIterable, Identifiable {
        case overview = "概览"
        case behaviors = "行为日志"
        case incidents = "异常记录"
        case adapters = "工具与规则"
        case settings = "设置"
        var id: Self { self }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(nsImage: AppBrandIcon.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 31, height: 31)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HarnessSentry").font(.subheadline.weight(.medium))
                        Text("本机行为审计").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, 13)
                .padding(.bottom, 10)
                List(Section.allCases, selection: $navigation.selection) { section in
                    HStack {
                        Label(section.rawValue, systemImage: icon(for: section))
                        Spacer(minLength: 2)
                        if section == .incidents && model.statistics.openIncidentCount > 0 {
                            Text("\(model.statistics.openIncidentCount)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .background(.red, in: Capsule())
                        }
                    }
                    .tag(section)
                }
                .listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status.rawValue).font(.caption.weight(.medium))
                    Text(model.resourceStatusDescription)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .padding(9)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch navigation.selection {
                case .overview: overview
                case .behaviors: behaviors
                case .incidents: incidents
                case .adapters: adapters
                case .settings: settings
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            await model.refresh()
            await model.refreshHookStatuses()
        }
        .confirmationDialog("清空行为日志？", isPresented: $viewState.showClearEventsConfirmation) {
            Button("清空行为日志", role: .destructive) { model.clearBehaviorLog() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("普通行为事件和异常证据时间线将被逻辑删除；异常摘要与允许规则仍保留。")
        }
        .confirmationDialog("清空全部本地记录？", isPresented: $viewState.showClearAllConfirmation) {
            Button("清空全部记录", role: .destructive) { model.clearAllRecords() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有行为和异常记录将被逻辑删除并压缩数据库；应用设置与允许规则仍保留。")
        }
        .confirmationDialog("清空全部异常记录？", isPresented: $viewState.showClearIncidentsConfirmation) {
            Button("清空异常记录", role: .destructive) { model.clearIncidents() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("包括未处理、已标记安全和固定的异常记录；行为日志、设置与允许规则仍保留。此操作无法撤销。")
        }
    }

    private var behaviors: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                title("行为日志", subtitle: "仅显示结构化元数据；Prompt、源码、命令正文和响应内容不会入库")
                Spacer()
                Button("导出证据…", systemImage: "square.and.arrow.up") { exportEvidence() }
                Button("清空日志…", role: .destructive) {
                    viewState.showClearEventsConfirmation = true
                }
                .disabled(model.events.isEmpty)
            }
            if model.events.isEmpty {
                ContentUnavailableView("暂无行为", systemImage: "waveform.path.ecg", description: Text("启动受支持的 Harness 后，进程和 Hook 事件会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                behaviorFilters
                if filteredEvents.isEmpty {
                    ContentUnavailableView.search(text: viewState.behaviorSearch)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(spacing: 0) {
                            HStack(spacing: 8) {
                                tableHeader("时间", width: 72)
                                tableHeader("状态", width: 56)
                                tableHeader("工具 / 会话", width: 135)
                                tableHeader("行为", width: 104)
                                tableHeader("范围或目标", width: 185)
                                tableHeader("数据量", width: 72)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.55))
                            ForEach(filteredEvents) { event in
                                behaviorTableRow(event)
                                    .contextMenu {
                                        Button("删除此行为记录", role: .destructive) { model.delete(event) }
                                    }
                                Divider()
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    private func tableHeader(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func behaviorTableRow(_ event: BehaviorEvent) -> some View {
        HStack(spacing: 8) {
            Text(event.timestamp, style: .time)
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .leading)
            Text(behaviorStatus(event))
                .foregroundStyle(event.metadata["mock"] == "true" ? .orange : .primary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(adapterName(event.toolID)).lineLimit(1)
                Text(event.sessionID.map { String($0.prefix(15)) } ?? "无会话")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 135, alignment: .leading)
            Text(event.type.rawValue)
                .frame(width: 104, alignment: .leading)
            Text(event.target ?? "—")
                .lineLimit(2)
                .frame(width: 185, alignment: .leading)
                .help(event.target ?? "未记录目标")
            Text(event.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                .frame(width: 72, alignment: .leading)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func behaviorStatus(_ event: BehaviorEvent) -> String {
        if event.metadata["mock"] == "true" { return "MOCK" }
        if let incident = model.incidents.first(where: { $0.id == event.id }) {
            return incident.disposition == .open ? "异常" : "已处置"
        }
        return "记录"
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                title("安全概览", subtitle: "仅统计本机已记录的行为；未采集的数据不会估算")
                Spacer()
                Label(model.status.rawValue, systemImage: overviewStatusSymbol)
                    .foregroundStyle(overviewStatusColor)
            }
            HStack(spacing: 10) {
                summaryCard("今日行为", value: "\(model.statistics.eventCount)", footnote: "已记录事件")
                summaryCard("未处理异常", value: "\(model.statistics.openIncidentCount)", footnote: "点击最近异常查看证据")
                summaryCard("文件读取", value: measuredBytes(for: [.fileOpen]), footnote: "仅显示有系统级字节证据")
                summaryCard("出站发送", value: measuredBytes(for: [.networkUpload]), footnote: "不代表设备总流量")
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("最近异常").font(.headline)
                                Spacer()
                                Button("查看全部") { navigation.selection = .incidents }
                                    .buttonStyle(.link)
                            }
                            Divider()
                            if model.incidents.isEmpty {
                                Text("暂无异常记录")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(model.incidents.prefix(3))) { incident in
                                    Button {
                                        viewState.selectedIncidentID = incident.id
                                        navigation.selection = .incidents
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "exclamationmark.shield")
                                                .foregroundStyle(incident.disposition == .open ? .red : .secondary)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(incident.title).foregroundStyle(.primary)
                                                Text("\(adapterName(incident.toolID)) · \(incident.severity)/100 · \(incident.createdAt.formatted(date: .omitted, time: .shortened))")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if incident.id != model.incidents.prefix(3).last?.id { Divider() }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("过去 12 小时行为量").font(.headline)
                            Text("最近已加载事件，最多 500 条；不是文件或网络总量")
                                .font(.caption).foregroundStyle(.secondary)
                            let buckets = overviewHourBuckets
                            let peak = max(buckets.max() ?? 0, 1)
                            HStack(alignment: .bottom, spacing: 5) {
                                ForEach(buckets.indices, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(buckets[index] > 0 ? Color.accentColor : Color.secondary.opacity(0.18))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: max(4, CGFloat(buckets[index]) / CGFloat(peak) * 76))
                                }
                            }
                            .frame(height: 78, alignment: .bottom)
                            HStack {
                                Text("12 小时前")
                                Spacer()
                                Text("现在")
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近观察到的工具").font(.headline)
                        Text("进程或 Hook 事件，不等于持续深度监控")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        if overviewRecentToolIDs.isEmpty {
                            Text("尚未观察到受支持工具")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(overviewRecentToolIDs, id: \.self) { id in
                                HStack {
                                    if let adapter = BuiltInAdapters.all.first(where: { $0.id == id }) {
                                        HarnessIconView(adapter: adapter, size: 24)
                                    }
                                    Text(adapterName(id))
                                    Spacer()
                                    Text(BuiltInAdapters.all.first(where: { $0.id == id })?.level.rawValue ?? "A1")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if id != overviewRecentToolIDs.last { Divider() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 225)
            }
        }
    }

    private var incidents: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                title("异常记录", subtitle: "先选记录，再核对摘要、来源和关联证据")
                Spacer()
                Button("全部标记安全") { model.markAllIncidentsSafe() }
                    .disabled(!model.incidents.contains(where: { $0.disposition == .open }))
                Button("清空异常记录…", role: .destructive) {
                    viewState.showClearIncidentsConfirmation = true
                }
                .disabled(model.incidents.isEmpty)
            }
            if model.incidents.isEmpty {
                ContentUnavailableView("暂无异常", systemImage: "checkmark.shield", description: Text("检测到异常行为后会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    List(model.incidents) { incident in
                        Button {
                            viewState.selectedIncidentID = incident.id
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(incident.title).font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    Spacer(minLength: 3)
                                    if incident.disposition == .open {
                                        Circle().fill(.red).frame(width: 7, height: 7)
                                    }
                                }
                                Text("\(adapterName(incident.toolID)) · \(incident.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(selectedIncident?.id == incident.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                    .frame(width: 250)
                    if let incident = selectedIncident {
                        ScrollView {
                            incidentDetail(incident)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .task(id: incident.id) { model.loadEvidence(for: incident) }
                    }
                }
            }
        }
    }

    private var selectedIncident: Incident? {
        model.incidents.first(where: { $0.id == viewState.selectedIncidentID }) ?? model.incidents.first
    }

    private func incidentDetail(_ incident: Incident) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(incident.title).font(.title3.weight(.semibold))
                    Text(incident.createdAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                dispositionBadge(incident.disposition)
            }
            Text(incident.summary)
                .font(.subheadline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((incident.disposition == .open ? Color.red : Color.green).opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    incidentTimelinePanel(incident).frame(minWidth: 240)
                    incidentFactsPanel(incident).frame(width: 175)
                }
                VStack(alignment: .leading, spacing: 12) {
                    incidentTimelinePanel(incident)
                    incidentFactsPanel(incident)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Button("导出全部证据…") { exportEvidence() }
                    if incident.disposition == .open {
                        Button("标记此条为安全") { model.markSafe(incident) }
                    }
                }
                HStack(spacing: 8) {
                    if incident.disposition == .open {
                        Button("以后允许此类行为…") { model.allowFuture(incident) }
                    }
                    Button("删除记录", role: .destructive) { model.delete(incident) }
                }
            }
            .controlSize(.small)
        }
    }

    private func incidentTimelinePanel(_ incident: Incident) -> some View {
        GroupBox("证据时间线") {
            incidentEvidenceTimeline(incident)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func incidentFactsPanel(_ incident: Incident) -> some View {
        GroupBox("事件信息") {
            VStack(spacing: 0) {
                incidentFact("工具", adapterName(incident.toolID))
                incidentFact("风险分数", "\(incident.severity)/100")
                incidentFact("证据级别", "L\(incident.evidence.rawValue)")
                incidentFact("会话", incident.sessionID ?? "未提供")
                incidentFact("来源", incident.title.hasPrefix("[Mock]") ? "Mock 演示" : "本机采集")
            }
        }
    }

    private func incidentFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled)
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var adapters: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("工具与规则", subtitle: "21 个内置识别器；“最近观察到”不代表文件和网络深度监控")
            if let lastAction = model.lastAction {
                Label(lastAction, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            List(BuiltInAdapters.all) { adapter in
                HStack(spacing: 11) {
                    HarnessIconView(adapter: adapter, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(adapter.displayName).font(.headline)
                        Text(adapter.executableNames.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(adapterVisibilityDescription(adapter))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let observed = model.events.first(where: { $0.toolID == adapter.id && $0.metadata["mock"] != "true" }) {
                            Text("最近观察到：\(observed.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("尚无本机记录")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if adapter.supportsHooks, let target = hookTarget(for: adapter.id) {
                        let installed = model.hookStatuses[target]?.isInstalled == true
                        Text(installed ? "Hook 已安装" : "Hook 未安装")
                            .font(.caption)
                            .foregroundStyle(installed ? .green : .secondary)
                        Button(installed ? "移除 Hook" : "安装 Hook") {
                            if installed {
                                model.uninstallHook(target)
                            } else {
                                model.installHook(target)
                            }
                        }
                        .buttonStyle(.borderless)
                        Button("复制配置") { model.copyHookConfiguration(adapterID: adapter.id) }
                            .buttonStyle(.borderless)
                    } else if adapter.id == "kiro" {
                        Menu("项目 Hook") {
                            Button("安装到项目…") { chooseKiroProject(remove: false) }
                            Button("从项目移除…") { chooseKiroProject(remove: true) }
                        }
                        .menuStyle(.borderlessButton)
                    } else if adapter.id == "opencode" {
                        Menu("项目插件") {
                            Button("安装到项目…") { chooseOpenCodeProject(remove: false) }
                            Button("从项目移除…") { chooseOpenCodeProject(remove: true) }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    Text(adapter.level.rawValue)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
            allowRulesPanel
        }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("数据与性能")
                        .font(.system(size: 20, weight: .medium))
                    Text("资源超预算时降低自身采样，不阻塞被监测工具")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                settingsSection("检测与通知") {
                    settingsRow("登录时启动", detail: "后台启动菜单栏应用") {
                        Toggle("登录时启动", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        .labelsHidden()
                    }
                    Divider()
                    settingsRow("异常系统通知", detail: model.notificationFeedback ?? "发现异常时发送系统通知") {
                        Toggle("异常系统通知", isOn: Binding(
                            get: { model.notificationsEnabled },
                            set: { model.setNotificationsEnabled($0) }
                        ))
                        .labelsHidden()
                        .disabled(model.notificationRequestInProgress)
                    }
                    if model.notificationPermissionDenied || model.notificationsEnabled {
                        Divider()
                        settingsRow("通知测试") {
                            if model.notificationPermissionDenied {
                                Button("打开系统通知设置") { model.openNotificationSettings() }
                            } else {
                                Button("发送测试通知") { model.sendTestNotification() }
                            }
                        }
                    }
                    Divider()
                    settingsRow("低影响模式", detail: "CPU、内存或磁盘超预算时自动降低扫描频率") {
                        Text("自动").foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("资源状态").font(.system(size: 13))
                        Text(model.resourceStatusDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    Divider()
                    settingsRow("CLI 扫描周期") {
                        Text("\(Int(model.resourceDecision.recommendedCLIScanInterval)) 秒")
                            .foregroundStyle(.secondary)
                    }
                }
                settingsSection("数据与隐私") {
                    settingsRow("行为日志保留", detail: "原始事件在 24 小时后自动聚合") {
                        Picker("行为日志保留", selection: Binding(
                            get: { model.retentionPolicy.behaviorDays },
                            set: { model.setBehaviorRetention(days: $0) }
                        )) {
                            ForEach([1, 2, 3, 7], id: \.self) { Text("\($0) 天").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 112)
                    }
                    Divider()
                    settingsRow("异常证据保留", detail: "仅保存结构化元数据") {
                        Picker("异常证据保留", selection: Binding(
                            get: { model.retentionPolicy.incidentDays },
                            set: { model.setIncidentRetention(days: $0) }
                        )) {
                            ForEach([2, 7, 30, 90], id: \.self) { Text("\($0) 天").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 112)
                    }
                    Divider()
                    settingsRow("磁盘硬上限", detail: "达到上限时优先清理最旧普通记录") {
                        Picker("磁盘硬上限", selection: Binding(
                            get: { Int(model.retentionPolicy.maximumDatabaseBytes / 1_024 / 1_024) },
                            set: { model.setMaximumDatabase(megabytes: $0) }
                        )) {
                            ForEach([100, 200, 500], id: \.self) { Text("\($0) MB").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 112)
                    }
                    Divider()
                    settingsRow("当前占用") {
                        Text(model.diskUsageDescription).foregroundStyle(.secondary)
                    }
                    Divider()
                    settingsRow("源码、Prompt 与请求正文") {
                        Text("始终不保存").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("导出本地证据 JSON…") { exportEvidence() }
                    Button("运行 Mock 异常链测试") { model.runMockScenario() }
                        .help("只生成带 mock=true 标记的虚构本地元数据，不读取文件、不访问网络")
                    Button("清空全部本地记录…", role: .destructive) {
                        viewState.showClearAllConfirmation = true
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsSection<Content: View>(
        _ heading: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        } label: {
            Text(heading).font(.system(size: 13, weight: .medium))
        }
    }

    private func settingsRow<Trailing: View>(
        _ label: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .padding(.vertical, 8)
    }

    private var allowRulesPanel: some View {
            GroupBox("允许规则") {
                if model.allowRules.isEmpty {
                    Text("暂无。可在异常记录中选择“以后允许”。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.allowRules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(rule.toolID ?? "所有工具") · \(rule.behaviorType?.rawValue ?? "所有行为")")
                                Text(rule.target ?? "所有目标")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("移除", role: .destructive) { model.deleteAllowRule(rule) }
                        }
                        if rule.id != model.allowRules.last?.id { Divider() }
                    }
                }
            }
    }

    private var filteredEvents: [BehaviorEvent] {
        let query = viewState.behaviorSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.events.filter { event in
            guard viewState.behaviorToolFilter == "*" || event.toolID == viewState.behaviorToolFilter else { return false }
            guard viewState.behaviorTypeFilter == "*" || event.type.rawValue == viewState.behaviorTypeFilter else { return false }
            if viewState.behaviorDateFilter == "today" && !Calendar.current.isDateInToday(event.timestamp) { return false }
            if viewState.behaviorDateFilter == "7days" && event.timestamp < Date().addingTimeInterval(-7 * 86_400) { return false }
            guard !query.isEmpty else { return true }

            let searchableFields = [
                event.target,
                event.sessionID,
                event.processPath,
                Optional(event.toolID),
                Optional(adapterName(event.toolID)),
                Optional(event.type.rawValue),
            ] + event.metadata.map { Optional("\($0.key) \($0.value)") }
            return searchableFields.compactMap { $0 }.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var behaviorFilters: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                TextField("搜索目标、会话或路径", text: $viewState.behaviorSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 330)
                Spacer()
                Text("\(filteredEvents.count) / \(model.events.count) 条已加载")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Picker("工具", selection: $viewState.behaviorToolFilter) {
                    Text("所有工具").tag("*")
                    ForEach(Array(Set(model.events.map(\.toolID))).sorted(), id: \.self) { toolID in
                        Text(adapterName(toolID)).tag(toolID)
                    }
                }
                .frame(width: 175)

                Picker("行为", selection: $viewState.behaviorTypeFilter) {
                    Text("所有行为").tag("*")
                    ForEach(BehaviorType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type.rawValue)
                    }
                }
                .frame(width: 160)

                Picker("日期", selection: $viewState.behaviorDateFilter) {
                    Text("今天").tag("today")
                    Text("最近 7 天").tag("7days")
                    Text("全部已加载").tag("all")
                }
                .frame(width: 125)

                if viewState.behaviorToolFilter != "*" || viewState.behaviorTypeFilter != "*" || viewState.behaviorDateFilter != "today" || !viewState.behaviorSearch.isEmpty {
                    Button("清除") {
                        viewState.behaviorSearch = ""
                        viewState.behaviorToolFilter = "*"
                        viewState.behaviorTypeFilter = "*"
                        viewState.behaviorDateFilter = "today"
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private func incidentEvidenceTimeline(_ incident: Incident) -> some View {
        if model.loadingEvidenceIDs.contains(incident.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取本地证据…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if let evidence = model.evidenceByIncidentID[incident.id], !evidence.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("关联证据 · \(evidence.count) 条")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 7)
                ForEach(Array(evidence.enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 2) {
                            Circle()
                                .fill(event.type == .networkUpload ? Color.red : Color.accentColor)
                                .frame(width: 7, height: 7)
                            if index < evidence.count - 1 {
                                Rectangle()
                                    .fill(.quaternary)
                                    .frame(width: 1, height: 30)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(event.timestamp, style: .time)
                                    .font(.caption.monospacedDigit())
                                Text(event.type.rawValue)
                                    .font(.caption.weight(.medium))
                                Text("证据 L\(event.evidence.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let target = event.target, !target.isEmpty {
                                Text(target)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        } else if model.evidenceByIncidentID[incident.id] != nil {
            Text("该记录没有可显示的关联事件；原始异常摘要仍保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    private func dispositionBadge(_ disposition: IncidentDisposition) -> some View {
        let label: String
        let color: Color
        switch disposition {
        case .open:
            label = "待处理"
            color = .orange
        case .safe:
            label = "已标记安全"
            color = .green
        case .resolved:
            label = "已解决"
            color = .blue
        }
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func title(_ text: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private func summaryCard(_ title: String, value: String, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
            Text(footnote).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func measuredBytes(for types: Set<BehaviorType>) -> String {
        let measured = model.events.filter {
            types.contains($0.type) && $0.metadata["mock"] != "true" &&
            $0.evidence >= .operatingSystem && $0.byteCount != nil
        }
        guard !measured.isEmpty else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: measured.reduce(0) { $0 + max($1.byteCount ?? 0, 0) },
            countStyle: .file
        )
    }

    private var overviewHourBuckets: [Int] {
        let now = Date()
        return (0..<12).map { offset in
            let lower = now.addingTimeInterval(Double(offset - 12) * 3_600)
            let upper = lower.addingTimeInterval(3_600)
            return model.events.filter { $0.timestamp >= lower && $0.timestamp < upper }.count
        }
    }

    private var overviewRecentToolIDs: [String] {
        var seen = Set<String>()
        return model.events
            .filter { $0.metadata["mock"] != "true" }
            .map(\.toolID)
            .filter { seen.insert($0).inserted }
            .prefix(5)
            .map { $0 }
    }

    private var overviewStatusSymbol: String {
        switch model.status {
        case .normal: "checkmark.shield"
        case .incident: "exclamationmark.shield"
        case .degraded: "shield.lefthalf.filled"
        case .paused: "pause.circle"
        case .starting: "shield"
        case .error: "xmark.shield"
        }
    }

    private var overviewStatusColor: Color {
        switch model.status {
        case .normal: .green
        case .incident, .error: .red
        case .degraded, .paused: .orange
        case .starting: .gray
        }
    }

    private func icon(for section: Section) -> String {
        switch section {
        case .overview: "rectangle.grid.2x2"
        case .behaviors: "waveform.path.ecg"
        case .incidents: "exclamationmark.shield"
        case .adapters: "terminal"
        case .settings: "gearshape"
        }
    }

    private func adapterName(_ id: String) -> String {
        BuiltInAdapters.all.first(where: { $0.id == id })?.displayName ?? id
    }

    private func hookTarget(for adapterID: String) -> HookIntegrationTarget? {
        switch adapterID {
        case "codex": .codex
        case "claude-code": .claudeCode
        case "workbuddy": .workBuddy
        case "qoder": .qoder
        case "zcode": .zcode
        case "cursor": .cursor
        case "windsurf": .windsurf
        case "copilot": .copilot
        case "gemini-cli": .geminiCLI
        case "qwen-code": .qwenCode
        case "continue": .continueCLI
        case "iflow-cli": .iFlowCLI
        case "kimi-cli": .kimiCLI
        case "goose": .goose
        case "cline": .cline
        case "trae": .trae
        default: nil
        }
    }

    private func adapterVisibilityDescription(_ adapter: HarnessAdapter) -> String {
        if adapter.id == "workbuddy" {
            return "深度会话：内置审计增量采集；Hook 可补充完整工具事件"
        }
        if adapter.id == "kiro" {
            return "深度会话：按项目安装 Hook，可见会话、工具与脱敏目标"
        }
        return switch adapter.level {
        case .deepSession: "深度会话：Hook 可见会话、工具与脱敏目标"
        case .enhanced: "增强识别：App 生命周期；深度行为需要系统传感器"
        case .basic: "基础识别：CLI 启动/退出；深度行为需要系统传感器"
        }
    }

    private func chooseKiroProject(remove: Bool) {
        let panel = NSOpenPanel()
        panel.title = remove ? "选择要移除 HarnessSentry Hook 的 Kiro 项目" : "选择要安装 HarnessSentry Hook 的 Kiro 项目"
        panel.prompt = remove ? "移除" : "安装"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if remove {
                model.removeKiroProjectHook(at: url)
            } else {
                model.installKiroProjectHook(at: url)
            }
        }
    }

    private func chooseOpenCodeProject(remove: Bool) {
        let panel = NSOpenPanel()
        panel.title = remove ? "选择要移除 HarnessSentry 插件的 OpenCode 项目" : "选择要安装 HarnessSentry 插件的 OpenCode 项目"
        panel.prompt = remove ? "移除" : "安装"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if remove {
                model.removeOpenCodeProjectPlugin(at: url)
            } else {
                model.installOpenCodeProjectPlugin(at: url)
            }
        }
    }

    private func behaviorIcon(_ type: BehaviorType) -> String {
        switch type {
        case .processLaunch, .processExit: "terminal"
        case .fileOpen, .fileCreate, .fileWrite, .fileRename, .fileDelete: "doc"
        case .directoryTraversal: "folder"
        case .archiveCreate: "archivebox"
        case .networkConnect, .networkUpload: "network"
        case .hookEvent: "link"
        case .monitorGap: "exclamationmark.triangle"
        }
    }

    private func exportEvidence() {
        let panel = NSSavePanel()
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        panel.nameFieldStringValue = "HarnessSentry-Evidence-\(day).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            model.exportEvidence(to: url)
        }
    }
}

@MainActor
final class DashboardNavigation: ObservableObject {
    @Published var selection: DashboardView.Section = .overview
}

@MainActor
private final class DashboardViewState: ObservableObject {
    @Published var selectedIncidentID: UUID?
    @Published var behaviorSearch = ""
    @Published var behaviorToolFilter = "*"
    @Published var behaviorTypeFilter = "*"
    @Published var behaviorDateFilter = "today"
    @Published var showClearEventsConfirmation = false
    @Published var showClearAllConfirmation = false
    @Published var showClearIncidentsConfirmation = false
}

@MainActor
private enum AppBrandIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }()
}
