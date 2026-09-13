import AppKit
import Combine
import Foundation

@MainActor
final class CodexTerminalLauncher: ObservableObject {
    @Published private(set) var message = "전용 Terminal 창에서만 Codex CLI 범위 입력이 실행됩니다."

    func chooseFolderAndLaunch() {
        let panel = NSOpenPanel()
        panel.title = "Codex CLI 작업 폴더 선택"
        panel.prompt = "여기서 열기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        launch(in: directory)
    }

    private func launch(in directory: URL) {
        let instanceID = "mac-\(UUID().uuidString.lowercased())"
        let shellCommand = "cd -- \(shellQuote(directory.path)) && export CODEX_KEYBOARD_INSTANCE_ID=\(shellQuote(instanceID)) && exec codex -c 'tui.terminal_title=[]'"
        let terminalCommand = "/bin/zsh -lic \(shellQuote(shellCommand))"
        let title = "Codex CLI - Keynob [\(instanceID)]"
        let source = """
        tell application "Terminal"
            activate
            set macroPadTab to do script "\(appleScriptEscape(terminalCommand))"
            set custom title of macroPadTab to "\(appleScriptEscape(title))"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            message = "Terminal 실행 실패: \(error[NSAppleScript.errorMessage] ?? "알 수 없는 오류")"
        } else {
            DedicatedCLIRegistry.shared.register(instanceID)
            message = "전용 Codex CLI를 열었습니다: \(directory.path)"
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
