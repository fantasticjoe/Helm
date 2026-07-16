import SwiftUI

/// 自绘面板呈现:替代 .sheet,支持点击空白处 / Esc 关闭。
/// 面板内部用 @Environment(\.panelDismiss) 关闭自己,调用方式与 dismiss() 一致。

private struct PanelDismissKey: EnvironmentKey {
    static let defaultValue: @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var panelDismiss: @Sendable () -> Void {
        get { self[PanelDismissKey.self] }
        set { self[PanelDismissKey.self] = newValue }
    }
}

extension View {
    func panel<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(PanelModifier(isPresented: isPresented, panelContent: content))
    }

    func panel<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        panel(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } })
        ) {
            if let value = item.wrappedValue {
                content(value)
            }
        }
    }
}

private struct PanelModifier<PanelContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let panelContent: () -> PanelContent

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if isPresented {
                    Color.black.opacity(0.30)
                        .ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                    panelContent()
                        .buttonStyle(HelmButtonStyle())
                        .environment(\.panelDismiss, { isPresented = false })
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.quaternary))
                        .shadow(color: .black.opacity(0.33), radius: 28, y: 10)
                        .onExitCommand { isPresented = false }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: isPresented)
        }
    }
}
