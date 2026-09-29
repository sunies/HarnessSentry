import AppKit
import HarnessSentryCore
import SwiftUI

struct MenuPopoverView: View {
    @ObservedObject var model: AppModel
    let openDashboard: () -> Void
    let openIncidents: () -> Void
    let quitApplication: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: statusSymbol)
                    .font(.system(size: menuPointSize + 3, weight: .regular))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.status.rawValue)
                        .font(menuFont)
                    Text(model.statusDetail)
                        .font(.system(size: menuPointSize - 1, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            insetDivider

            valueRow(title: "今日行为", value: "\(model.statistics.eventCount)")
            valueRow(title: "未处理", value: "\(model.statistics.openIncidentCount)")
            valueRow(title: "日志占用", value: model.diskUsageDescription)

            insetDivider

            VStack(alignment: .leading, spacing: 6) {
                Text("最近异常")
                    .font(menuFont)
                    .foregroundStyle(.secondary)
                if let incident = model.incidents.first(where: { $0.disposition == .open }) {
                    Text(incident.title)
                        .font(menuFont)
                    Text(incident.summary)
                        .font(.system(size: menuPointSize - 1, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack {
                        Text("风险 \(incident.severity)/100")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .font(.system(size: menuPointSize - 1, weight: .regular))
                } else {
                    Text("暂无未处理异常")
                        .font(menuFont)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let lastError = model.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: menuPointSize - 1, weight: .regular))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            insetDivider

            if let incident = model.incidents.first(where: { $0.disposition == .open }) {
                menuButton("标记为安全") { model.markSafe(incident) }
                menuButton("以后允许") { model.allowFuture(incident) }
                insetDivider
            }

            menuButton(model.status == .paused ? "继续监控" : "暂停监控") {
                model.togglePause()
            }
            if model.statistics.openIncidentCount > 0 {
                menuButton("查看异常", showsChevron: true, action: openIncidents)
            }
            menuButton("打开仪表盘", showsChevron: true, action: openDashboard)

            insetDivider

            menuButton("退出 HarnessSentry", action: quitApplication)

            #if DEBUG
            menuButton("生成本地测试异常", systemImage: "ladybug") {
                model.createTestIncident()
            }
            #endif
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var menuPointSize: CGFloat {
        NSFont.menuFont(ofSize: 0).pointSize
    }

    private var menuFont: Font {
        .system(size: menuPointSize, weight: .regular)
    }

    private var insetDivider: some View {
        Divider()
            .padding(.horizontal, 16)
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(menuFont)
            Spacer()
            Text(value)
                .font(menuFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func menuButton(
        _ title: String,
        systemImage: String? = nil,
        showsChevron: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16)
                }
                Text(title)
                    .font(menuFont)
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: menuPointSize - 1, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private var statusSymbol: String {
        switch model.status {
        case .normal: "checkmark.shield.fill"
        case .incident: "exclamationmark.shield.fill"
        case .degraded: "shield.lefthalf.filled"
        case .paused: "pause.circle.fill"
        case .starting: "shield"
        case .error: "xmark.shield.fill"
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .normal: .green
        case .incident: .red
        case .degraded: .orange
        case .paused: .orange
        case .starting: .gray
        case .error: .red
        }
    }
}
