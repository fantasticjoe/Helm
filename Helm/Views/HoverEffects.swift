import SwiftUI

/// 行 / chip 的统一悬停高亮:中性淡底色,0.12s 渐显渐隐。
struct HoverHighlightModifier: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: cornerRadius))
    }
}

/// 全 app 统一按钮样式:悬停增亮、按压微缩、destructive 红字、禁用降透明。
/// 在容器上 .buttonStyle(HelmButtonStyle()) 级联,子按钮自动获得交互反馈。
struct HelmButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, prominent: prominent)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        private var isDestructive: Bool { configuration.role == .destructive }

        private var fill: Color {
            if prominent {
                return Color.accentColor
                    .opacity(configuration.isPressed ? 0.72 : hovering ? 0.86 : 1)
            }
            let base: Color = isDestructive ? .red : .primary
            return base.opacity(configuration.isPressed ? 0.18 : hovering ? 0.13 : 0.08)
        }

        private var textStyle: AnyShapeStyle {
            if prominent { return AnyShapeStyle(.white) }
            if isDestructive { return AnyShapeStyle(Color.red) }
            return AnyShapeStyle(.primary)
        }

        var body: some View {
            configuration.label
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
                .foregroundStyle(textStyle)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// 统一的小关闭钮:平时若隐,悬停变实并出现圆形底。
struct CloseChipButton: View {
    var help = "关闭标签页"
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}
