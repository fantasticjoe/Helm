import AppKit
import Foundation
import SwiftUI

/// 会话入口的统一分发:按用户偏好走内嵌终端窗口或外部终端 app。
@MainActor
enum SessionLauncher {
    static func open(_ host: Host, openWindow: OpenWindowAction) {
        if TerminalLauncher.useBuiltin {
            openWindow(id: "terminal", value: TerminalSessionRequest(alias: host.meta.alias))
            NSApp.activate(ignoringOtherApps: true)
        } else {
            TerminalLauncher.open(command: SSHService.sessionCommandLine(for: host))
        }
    }
}

@MainActor
enum TerminalLauncher {
    enum TerminalApp: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case iterm = "iTerm2"

        var id: String { rawValue }

        var bundleIdentifier: String {
            switch self {
            case .terminal: "com.apple.Terminal"
            case .iterm: "com.googlecode.iterm2"
            }
        }

        var isInstalled: Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        }
    }

    static let builtinValue = "builtin"

    static var useBuiltin: Bool {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.preferredTerminal)
        return raw == nil || raw!.isEmpty || raw == builtinValue
    }

    static var preferred: TerminalApp {
        if let raw = UserDefaults.standard.string(forKey: SettingsKeys.preferredTerminal),
           let app = TerminalApp(rawValue: raw), app.isInstalled {
            return app
        }
        return TerminalApp.iterm.isInstalled ? .iterm : .terminal
    }

    static func open(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch preferred {
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        case .iterm:
            script = """
            tell application "iTerm"
                activate
                create window with default profile command "\(escaped)"
            end tell
            """
        }
        Task.detached(priority: .userInitiated) {
            _ = await ProcessRunner.run("/usr/bin/osascript", arguments: ["-e", script], timeout: 15)
        }
    }
}

enum SettingsKeys {
    static let pollInterval = "pollInterval"
    static let preferredTerminal = "preferredTerminal"
    static let diskThreshold = "diskThreshold"
    static let notifyOffline = "notifyOffline"
    static let notifyDisk = "notifyDisk"
}
