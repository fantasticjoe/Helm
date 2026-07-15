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
