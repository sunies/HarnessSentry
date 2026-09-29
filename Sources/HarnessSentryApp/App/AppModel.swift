import AppKit
import Combine
import Foundation
import HarnessSentryCore
import HarnessSentryESSensor

enum ProtectionStatus: String {
    case normal = "保护中"
    case incident = "发现异常"
    case degraded = "低影响模式"
    case paused = "已暂停"
    case starting = "启动中"
    case error = "监测故障"
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var status: ProtectionStatus = .starting
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var events: [BehaviorEvent] = []
    @Published private(set) var evidenceByIncidentID: [UUID: [BehaviorEvent]] = [:]
    @Published private(set) var loadingEvidenceIDs = Set<UUID>()
    @Published private(set) var statistics = StoreStatistics(eventCount: 0, openIncidentCount: 0, databaseBytes: 0)
    @Published private(set) var endpointSecurityAvailability: EndpointSecurityAvailability = .unsupported
    @Published private(set) var lastError: String?
    @Published private(set) var lastAction: String?
    @Published private(set) var allowRules: [AllowRule] = []
    @Published private(set) var hookStatuses: [HookIntegrationTarget: HookIntegrationStatus] = [:]
    @Published private(set) var resourceSnapshot = ResourceHealthSnapshot(
        cpuAveragePercent: 0,
        residentMemoryBytes: 0,
        databaseBytes: 0,
        databaseLimitBytes: RetentionPolicy.default.maximumDatabaseBytes
    )
    @Published private(set) var resourceDecision = ResourceGovernorDecision(
        state: .normal,
        recommendedCLIScanInterval: 10,
        reasons: []
    )
    @Published var launchAtLogin = false
    @Published var notificationsEnabled = false
    @Published private(set) var notificationRequestInProgress = false
    @Published private(set) var notificationPermissionDenied = false
    @Published private(set) var notificationFeedback: String?
    @Published var retentionPolicy = RetentionPolicy.default

    private let store: SQLiteEventStore?
    private let endpointSecuritySensor = EndpointSecuritySensor()
    private var workspaceProcessSensor: WorkspaceProcessSensor?
    private var cliProcessSensor: CLIProcessSensor?
    private var workBuddyAuditSensor: WorkBuddyAuditSensor?
    private var retentionTask: Task<Void, Never>?
    private var resourceTask: Task<Void, Never>?
    private var dataChangeObserver: NSObjectProtocol?
    private var knownIncidentIDs = Set<UUID>()
    private var hasLoadedInitialState = false
    private var isPaused = false
    private var monitoringError: String?
    private let resourceMonitor = ResourceMonitor()
    private let developerMockSensor = DeveloperMockSensor()
    private let hookIntegrationService = HookIntegrationService()
    private let kiroProjectHookService = KiroProjectHookService()
    private let openCodeProjectPluginService = OpenCodeProjectPluginService()

    init() {
        let defaults = UserDefaults.standard
        retentionPolicy = RetentionPolicy(
            rawEventHours: 24,
            behaviorDays: defaults.object(forKey: "retention.behaviorDays") as? Int ?? 2,
            incidentDays: defaults.object(forKey: "retention.incidentDays") as? Int ?? 30,
            maximumDatabaseBytes: Int64(defaults.object(forKey: "retention.maximumMegabytes") as? Int ?? 200) * 1_024 * 1_024
        )
        launchAtLogin = SystemIntegrationService.launchAtLoginEnabled
        notificationsEnabled = defaults.bool(forKey: "notifications.enabled")
        isPaused = defaults.bool(forKey: "monitoring.paused")
        do {
            let databaseURL = try SQLiteEventStore.defaultDatabaseURL()
            store = try SQLiteEventStore(url: databaseURL)
        } catch {
            store = nil
            monitoringError = "无法打开本地数据库：\(error.localizedDescription)"
            lastError = monitoringError
        }
    }

    func start() {
        if !isPaused { startCommunitySensors() }
        updateStatus()

        dataChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.harnesssentry.dataChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }

        retentionTask?.cancel()
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }

        resourceTask?.cancel()
        resourceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.updateResourceHealth()
                try? await Task.sleep(for: .seconds(10))
            }
        }

        Task {
            await refreshNotificationAuthorization()
            if let persistedPause = try? await store?.isMonitoringPaused() {
                isPaused = persistedPause
                UserDefaults.standard.set(persistedPause, forKey: "monitoring.paused")
                if persistedPause {
                    stopCommunitySensors()
                } else {
                    startCommunitySensors()
                }
                updateStatus()
            }
            endpointSecurityAvailability = EndpointSecurityProbe.check()
            await refresh()
            await refreshHookStatuses()
        }
    }

    func stop() {
        retentionTask?.cancel()
        retentionTask = nil
        resourceTask?.cancel()
        resourceTask = nil
        developerMockSensor.stop()
        stopCommunitySensors()
        if let dataChangeObserver {
            DistributedNotificationCenter.default().removeObserver(dataChangeObserver)
            self.dataChangeObserver = nil
        }
    }

    func refresh() async {
        guard let store else {
            monitoringError = monitoringError ?? "本地数据库不可用"
            updateStatus()
            return
        }
        do {
            statistics = try await store.enforceRetention(retentionPolicy)
            let fetchedIncidents = try await store.fetchIncidents()
            if hasLoadedInitialState, notificationsEnabled {
                for incident in fetchedIncidents where incident.disposition == .open && !knownIncidentIDs.contains(incident.id) {
                    do {
                        try await SystemIntegrationService.notify(incident)
                    } catch {
                        lastError = "无法发送异常通知：\(error.localizedDescription)"
                    }
                }
            }
            incidents = fetchedIncidents
            knownIncidentIDs = Set(fetchedIncidents.map(\.id))
            hasLoadedInitialState = true
            events = try await store.fetchEvents(limit: 500)
            allowRules = try await store.fetchAllowRules()
            monitoringError = nil
            updateStatus()
        } catch {
            lastError = String(describing: error)
            monitoringError = "本地记录读取失败：\(error.localizedDescription)"
            updateStatus()
        }
    }

    func togglePause() {
        isPaused.toggle()
        let nextState = isPaused
        UserDefaults.standard.set(nextState, forKey: "monitoring.paused")
        if nextState {
            developerMockSensor.stop()
            stopCommunitySensors()
        } else {
            startCommunitySensors()
        }
        updateStatus()
        Task {
            do {
                try await store?.setMonitoringPaused(nextState, source: "menu-bar-app")
            } catch {
                lastError = "无法同步监控状态：\(error.localizedDescription)"
            }
        }
    }

    func runMockScenario() {
        developerMockSensor.start(enabled: true) { [weak self] event in
            Task { @MainActor [weak self] in self?.ingest(event) }
        }
        lastAction = "正在回放明确标记为 Mock 的本地测试事件"
    }

    func refreshHookStatuses() async {
        for target in HookIntegrationTarget.allCases {
            do {
                hookStatuses[target] = try await hookIntegrationService.status(for: target)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func installHook(_ target: HookIntegrationTarget) {
        Task {
            do {
                let result = try await hookIntegrationService.install(target)
                lastAction = switch result.action {
                case .alreadyInstalled: "\(target.displayName) Hook 已经安装"
                case .updated: "已更新 \(target.displayName) Hook，并备份原配置"
                default: "已安装 \(target.displayName) Hook"
                }
                await refreshHookStatuses()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func uninstallHook(_ target: HookIntegrationTarget) {
        Task {
            do {
                let result = try await hookIntegrationService.uninstall(target)
                lastAction = result.action == .alreadyRemoved
                    ? "\(target.displayName) Hook 尚未安装"
                    : "已移除 \(target.displayName) Hook；其他配置保持不变"
                await refreshHookStatuses()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func installKiroProjectHook(at projectURL: URL) {
        Task {
            do {
                let result = try await kiroProjectHookService.install(projectURL: projectURL)
                lastAction = result.backupURL == nil
                    ? "已安装 Kiro 项目 Hook：\(result.configurationURL.deletingLastPathComponent().path)"
                    : "已更新 Kiro 项目 Hook，并备份原文件"
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeKiroProjectHook(at projectURL: URL) {
        Task {
            do {
                let backup = try await kiroProjectHookService.remove(projectURL: projectURL)
                lastAction = backup == nil ? "该项目没有 HarnessSentry Kiro Hook" : "已移除 Kiro 项目 Hook，并保留备份"
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func installOpenCodeProjectPlugin(at projectURL: URL) {
        Task {
            do {
                let result = try await openCodeProjectPluginService.install(projectURL: projectURL)
                lastAction = result.backupURL == nil
                    ? "已安装 OpenCode 项目插件：\(result.configurationURL.deletingLastPathComponent().path)"
                    : "已更新 OpenCode 项目插件，并备份原文件"
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeOpenCodeProjectPlugin(at projectURL: URL) {
        Task {
            do {
                let backup = try await openCodeProjectPluginService.remove(projectURL: projectURL)
                lastAction = backup == nil
                    ? "该项目尚未安装 OpenCode HarnessSentry 插件"
                    : "已移除 OpenCode 项目插件，并保留备份"
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func setBehaviorRetention(days: Int) {
        retentionPolicy.behaviorDays = days
        UserDefaults.standard.set(days, forKey: "retention.behaviorDays")
        Task { await refresh() }
    }

    func setIncidentRetention(days: Int) {
        retentionPolicy.incidentDays = days
        UserDefaults.standard.set(days, forKey: "retention.incidentDays")
        Task { await refresh() }
    }

    func setMaximumDatabase(megabytes: Int) {
        retentionPolicy.maximumDatabaseBytes = Int64(megabytes) * 1_024 * 1_024
        UserDefaults.standard.set(megabytes, forKey: "retention.maximumMegabytes")
        Task { await refresh() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try SystemIntegrationService.setLaunchAtLogin(enabled)
            launchAtLogin = SystemIntegrationService.launchAtLoginEnabled
        } catch {
            launchAtLogin = SystemIntegrationService.launchAtLoginEnabled
            lastError = "无法修改登录项：\(error.localizedDescription)"
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard !notificationRequestInProgress else { return }
        if !enabled {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "notifications.enabled")
            notificationFeedback = "异常系统通知已关闭。"
            return
        }
        notificationRequestInProgress = true
        notificationFeedback = "正在检查 macOS 通知权限…"
        Task {
            defer { notificationRequestInProgress = false }
            do {
                let granted = try await SystemIntegrationService.requestNotificationPermission()
                let status = await SystemIntegrationService.notificationAuthorizationStatus()
                let enabled = granted && status == .authorized
                notificationsEnabled = enabled
                notificationPermissionDenied = status == .denied
                UserDefaults.standard.set(enabled, forKey: "notifications.enabled")
                if enabled {
                    notificationFeedback = "已开启。可发送测试通知确认系统横幅是否正常。"
                } else {
                    notificationFeedback = status == .denied
                        ? "macOS 已拒绝通知权限。请在系统设置 > 通知中允许 HarnessSentry。"
                        : "系统尚未授予横幅通知权限。请检查系统设置 > 通知。"
                }
            } catch {
                notificationsEnabled = false
                UserDefaults.standard.set(false, forKey: "notifications.enabled")
                notificationFeedback = "请求通知权限失败：\(error.localizedDescription)"
                lastError = notificationFeedback
            }
        }
    }

    func refreshNotificationAuthorization() async {
        guard !notificationRequestInProgress else { return }
        let status = await SystemIntegrationService.notificationAuthorizationStatus()
        notificationPermissionDenied = status == .denied
        if notificationsEnabled && status != .authorized {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "notifications.enabled")
        }
        if status == .denied {
            notificationFeedback = "macOS 已拒绝通知权限。请在系统设置 > 通知中允许 HarnessSentry。"
        } else if status == .authorized {
            notificationFeedback = notificationsEnabled
                ? "已开启。可发送测试通知确认系统横幅是否正常。"
                : "macOS 已授权；打开开关即可接收异常通知。"
        } else if status == .notDetermined {
            notificationFeedback = "开启时 macOS 会询问是否允许通知。"
        } else {
            notificationFeedback = "当前不是完整的横幅通知授权；请检查系统设置 > 通知。"
        }
    }

    func openNotificationSettings() {
        SystemIntegrationService.openNotificationSettings()
    }

    func sendTestNotification() {
        Task {
            do {
                try await SystemIntegrationService.sendTestNotification()
                notificationFeedback = "测试通知已提交给 macOS；如未显示，请检查系统通知设置或专注模式。"
            } catch {
                notificationFeedback = "测试通知发送失败：\(error.localizedDescription)"
                lastError = notificationFeedback
            }
        }
    }

    func markSafe(_ incident: Incident) {
        Task {
            do {
                try await store?.markIncidentSafe(id: incident.id)
                await refresh()
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func markAllIncidentsSafe() {
        Task {
            do {
                try await store?.markAllOpenIncidentsSafe()
                lastAction = "已将全部未处理异常标记为安全"
                await refresh()
            } catch {
                lastError = "无法批量标记异常：\(error.localizedDescription)"
            }
        }
    }

    func clearIncidents() {
        Task {
            do {
                try await store?.clearIncidents()
                evidenceByIncidentID.removeAll()
                knownIncidentIDs.removeAll()
                lastAction = "已清空异常记录；行为日志仍然保留"
                await refresh()
            } catch {
                lastError = "无法清空异常记录：\(error.localizedDescription)"
            }
        }
    }

    func delete(_ incident: Incident) {
        Task {
            do {
                try await store?.deleteIncident(id: incident.id)
                evidenceByIncidentID.removeValue(forKey: incident.id)
                await refresh()
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func delete(_ event: BehaviorEvent) {
        Task {
            do {
                try await store?.deleteEvent(id: event.id)
                await refresh()
            } catch {
                lastError = "无法删除行为记录：\(error.localizedDescription)"
            }
        }
    }

    func clearBehaviorLog() {
        Task {
            do {
                try await store?.clearEvents()
                evidenceByIncidentID.removeAll()
                lastAction = "已清空行为日志；异常摘要仍然保留"
                await refresh()
            } catch {
                lastError = "无法清空行为日志：\(error.localizedDescription)"
            }
        }
    }

    func clearAllRecords() {
        Task {
            do {
                try await store?.clearAllRecords(preservingSettings: true)
                evidenceByIncidentID.removeAll()
                knownIncidentIDs.removeAll()
                lastAction = "已清空全部行为和异常记录；设置与允许规则已保留"
                await refresh()
            } catch {
                lastError = "无法清空本地记录：\(error.localizedDescription)"
            }
        }
    }

    /// Loads immutable evidence only when an incident is opened in the UI. Results are
    /// cached in memory so expanding rows does not repeatedly query SQLite.
    func loadEvidence(for incident: Incident) {
        guard evidenceByIncidentID[incident.id] == nil,
              !loadingEvidenceIDs.contains(incident.id),
              let store
        else { return }

        loadingEvidenceIDs.insert(incident.id)
        Task {
            do {
                evidenceByIncidentID[incident.id] = try await store.fetchEvents(forIncidentID: incident.id)
            } catch {
                lastError = "无法读取异常证据：\(error.localizedDescription)"
            }
            loadingEvidenceIDs.remove(incident.id)
        }
    }

    func allowFuture(_ incident: Incident) {
        guard let store else { return }
        Task {
            do {
                let evidence = try await store.fetchEvents(forIncidentID: incident.id)
                guard let event = evidence.last else {
                    lastError = "该异常没有可用于创建允许规则的行为证据"
                    return
                }
                guard let target = event.target, !target.isEmpty else {
                    lastError = "该异常缺少明确目标，不能创建过宽的允许规则；可仅标记当前记录为安全"
                    return
                }
                let rule = AllowRule(
                    toolID: event.toolID,
                    behaviorType: event.type,
                    target: target,
                    note: "由异常“\(incident.title)”创建"
                )
                try await store.insert(allowRule: rule)
                try await store.markIncidentSafe(id: incident.id)
                await refresh()
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func deleteAllowRule(_ rule: AllowRule) {
        Task {
            do {
                try await store?.deleteAllowRule(id: rule.id)
                await refresh()
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func exportEvidence(to url: URL) {
        guard let store else { return }
        Task {
            do {
                let snapshot = try await store.exportEvidence()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func copyHookConfiguration(adapterID: String) {
        guard HookConfigurationBuilder.supportedAdapterIDs.contains(adapterID)
                || ManagedHookArtifactBuilder.supportedAdapterIDs.contains(adapterID) else { return }
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let hookPath = executableDirectory?.appendingPathComponent("HarnessSentryHook").path ?? "HarnessSentryHook"
        do {
            let data = HookConfigurationBuilder.supportedAdapterIDs.contains(adapterID)
                ? try HookConfigurationBuilder.data(executablePath: hookPath, adapterID: adapterID)
                : try ManagedHookArtifactBuilder.data(executablePath: hookPath, adapterID: adapterID)
            guard let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let displayName = BuiltInAdapters.all.first(where: { $0.id == adapterID })?.displayName ?? adapterID
            lastAction = "已复制 \(displayName) Hook 配置"
        } catch {
            lastError = "无法生成 Hook 配置：\(error.localizedDescription)"
        }
    }

    #if DEBUG
    func createTestIncident() {
        guard let store else { return }
        let sessionID = "qdr_\(UUID().uuidString.prefix(6).lowercased())"
        let event = BehaviorEvent(
            sessionID: sessionID,
            toolID: "qoder",
            processID: 42_001,
            processPath: "/Applications/Qoder.app/Contents/MacOS/qoder-helper",
            type: .archiveCreate,
            target: "/private/var/folders/.../checkpoint.bin",
            byteCount: 281_700_000,
            evidence: .correlated,
            metadata: ["source": "debug-replay"]
        )
        let incident = Incident(
            id: event.id,
            toolID: "qoder",
            sessionID: sessionID,
            title: "Qoder 后台创建大型代码归档",
            summary: "会话空闲期遍历 Git 对象并创建 281.7 MB 临时归档。当前为测试记录。",
            severity: 92,
            evidence: .correlated
        )

        Task {
            do {
                try await store.record(event: event, evaluation: RuleEvaluation(incident: incident, evidenceEventIDs: [event.id]))
                await refresh()
            } catch {
                lastError = String(describing: error)
            }
        }
    }
    #endif

    var statusDetail: String {
        if isPaused { return "监控已由用户暂停" }
        if let monitoringError { return monitoringError }
        if statistics.openIncidentCount > 0 { return "\(statistics.openIncidentCount) 条异常等待处理" }
        if status == .degraded { return resourceStatusDescription }
        if status == .starting { return "正在启动基础监测" }
        if endpointSecurityAvailability == .available { return "完整监测运行中" }
        return "基础监测运行中"
    }

    var diskUsageDescription: String {
        let used = ByteCountFormatter.string(fromByteCount: statistics.databaseBytes, countStyle: .file)
        let maximum = ByteCountFormatter.string(fromByteCount: retentionPolicy.maximumDatabaseBytes, countStyle: .file)
        return "\(used) / \(maximum)"
    }

    var resourceStatusDescription: String {
        let memory = ByteCountFormatter.string(fromByteCount: resourceSnapshot.residentMemoryBytes, countStyle: .memory)
        let cpu = resourceSnapshot.cpuAveragePercent.formatted(.number.precision(.fractionLength(1)))
        if resourceDecision.state == .normal { return "CPU \(cpu)% · 内存 \(memory)" }
        let reasons = resourceDecision.reasons.map {
            switch $0 {
            case .cpu: "CPU"
            case .memory: "内存"
            case .database: "数据库"
            }
        }.joined(separator: "、")
        return "低影响模式（\(reasons)）· CPU \(cpu)% · 内存 \(memory)"
    }

    private func updateStatus() {
        if isPaused {
            status = .paused
        } else if monitoringError != nil {
            status = .error
        } else if statistics.openIncidentCount > 0 {
            status = .incident
        } else if resourceDecision.state == .throttled {
            status = .degraded
        } else {
            status = .normal
        }
    }

    private func updateResourceHealth() {
        resourceSnapshot = resourceMonitor.sample(
            databaseBytes: statistics.databaseBytes,
            databaseLimitBytes: retentionPolicy.maximumDatabaseBytes
        )
        let nextDecision = ResourceGovernor.evaluate(resourceSnapshot)
        if nextDecision.recommendedCLIScanInterval != resourceDecision.recommendedCLIScanInterval {
            cliProcessSensor?.updateScanInterval(nextDecision.recommendedCLIScanInterval)
        }
        resourceDecision = nextDecision
        updateStatus()
    }

    private func startCommunitySensors() {
        if workspaceProcessSensor == nil {
            let processSensor = WorkspaceProcessSensor()
            processSensor.start { [weak self] event in self?.ingest(event) }
            workspaceProcessSensor = processSensor
        }
        if cliProcessSensor == nil {
            let cliSensor = CLIProcessSensor()
            cliSensor.start { [weak self] event in
                Task { @MainActor in self?.ingest(event) }
            }
            cliSensor.updateScanInterval(resourceDecision.recommendedCLIScanInterval)
            cliProcessSensor = cliSensor
        }
        if workBuddyAuditSensor == nil {
            let auditSensor = WorkBuddyAuditSensor()
            auditSensor.start { [weak self] event in
                Task { @MainActor in self?.ingest(event) }
            }
            workBuddyAuditSensor = auditSensor
        }
    }

    private func stopCommunitySensors() {
        workspaceProcessSensor?.stop()
        workspaceProcessSensor = nil
        cliProcessSensor?.stop()
        cliProcessSensor = nil
        workBuddyAuditSensor?.stop()
        workBuddyAuditSensor = nil
    }

    private func ingest(_ event: BehaviorEvent) {
        guard !isPaused, let store else { return }
        Task {
            do {
                let recent = try await store.fetchEvents(limit: 200, since: event.timestamp.addingTimeInterval(-300), toolID: event.toolID)
                let allowed = try await store.isAllowed(event)
                let evaluation = allowed ? nil : AnomalyRuleEngine.evaluate(event: event, recentEvents: recent)
                try await store.record(event: event, evaluation: evaluation)
                statistics = try await store.statistics()
                if let evaluation {
                    incidents.insert(evaluation.incident, at: 0)
                    knownIncidentIDs.insert(evaluation.incident.id)
                    if notificationsEnabled {
                        do {
                            try await SystemIntegrationService.notify(evaluation.incident)
                        } catch {
                            lastError = "无法发送异常通知：\(error.localizedDescription)"
                        }
                    }
                }
                events.insert(event, at: 0)
                if events.count > 500 { events.removeLast(events.count - 500) }
                updateStatus()
            } catch {
                lastError = String(describing: error)
                monitoringError = "本地记录写入失败：\(error.localizedDescription)"
                updateStatus()
            }
        }
    }
}
