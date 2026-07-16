import SwiftUI

extension ConnectionState {
    var color: Color {
        switch self {
        case .online: .green
        case .connecting: .yellow
        case .unreachable: .red
        case .authFailed: .orange
        case .disconnected: .gray.opacity(0.45)
        }
    }

    var label: String {
        switch self {
        case .online: "在线"
        case .connecting: "连接中"
        case .unreachable: "不可达"
        case .authFailed: "认证失败"
        case .disconnected: "未连接"
        }
    }
}

func usageColor(_ percent: Int) -> Color {
    if percent >= 90 { return .red }
    if percent >= 80 { return .orange }
    return .accentColor
}

func gigabytesFromKB(_ kb: Int64) -> String {
    let gb = Double(kb) / 1_048_576
    return gb >= 1000 ? String(format: "%.1fT", gb / 1024) : String(format: "%.0fG", gb)
}

func gigabytesFromMB(_ mb: Int) -> String {
    let gb = Double(mb) / 1024
    return gb < 10 ? String(format: "%.1fG", gb) : String(format: "%.0fG", gb)
}

struct StatusDot: View {
    let state: ConnectionState
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .shadow(color: state.color.opacity(state == .online ? 0.5 : 0), radius: 3)
    }
}

struct CapacityBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .animation(.easeInOut(duration: 0.25), value: fraction)
    }
}

struct MetricCell: View {
    let label: String
    let value: String
    var percent: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let percent {
                CapacityBar(fraction: Double(percent) / 100, tint: usageColor(percent))
            }
        }
    }
}

struct CapabilityChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
            .foregroundStyle(.secondary)
    }
}
