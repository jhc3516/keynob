import AppKit
import SwiftUI
import KeynobCore

@MainActor
private final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var message = "기록을 누른 뒤 원하는 조합을 함께 누르세요. 키 하나를 놓으면 기록이 완료됩니다."
    private var monitor: Any?
    private var capture = ShortcutCapture()
    private var heldModifierKeys = Set<UInt16>()
    private weak var window: NSWindow?

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { message = "기록을 취소했습니다. 기존 단축키는 유지됩니다." }
        isRecording = false
    }

    func begin(completion: @escaping (DeviceShortcut) -> Void) {
        cancel()
        capture = ShortcutCapture()
        heldModifierKeys.removeAll()
        window = NSApp.keyWindow
        isRecording = true
        message = "기록 중… 조합 중 키 하나를 놓으면 기록이 완료됩니다. Escape도 기록됩니다. 취소는 버튼을 누르세요."
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isRecording else { return false }
                guard NSApp.keyWindow === self.window else { self.cancel(); return false }
                let flags = event.modifierFlags
                var modifiers = Set<UInt8>()
                if flags.contains(.control) { modifiers.insert(0xF1) }
                if flags.contains(.shift) { modifiers.insert(0xF2) }
                if flags.contains(.option) { modifiers.insert(0xF3) }
                if flags.contains(.command) { modifiers.insert(0xF4) }
                // Caps Lock is a toggle, not a held modifier; offer it through direct selection.
                if event.type == .flagsChanged && event.keyCode == 57 {
                    self.cancel()
                    self.message = "Caps Lock은 직접 선택에서 지정하세요. 기존 단축키는 유지됩니다."
                    return true
                }
                // Track physical sides too: releasing left Shift must finish even while right Shift is held.
                let modifierFlags: [UInt16: NSEvent.ModifierFlags] = [
                    54: .command, 55: .command, 56: .shift, 60: .shift,
                    58: .option, 61: .option, 59: .control, 62: .control
                ]
                var modifierReleased = false
                if event.type == .flagsChanged, let flag = modifierFlags[event.keyCode] {
                    modifierReleased = !flags.contains(flag) || self.heldModifierKeys.contains(event.keyCode)
                    if modifierReleased { self.heldModifierKeys.remove(event.keyCode) }
                    else { self.heldModifierKeys.insert(event.keyCode) }
                }
                let result = self.capture.update(
                    keyCode: event.type == .flagsChanged ? nil : event.keyCode,
                    down: event.type == .keyDown, modifiers: modifiers, modifierReleased: modifierReleased)
                if let result {
                    self.cancel()
                    switch result {
                    case .success(let shortcut):
                        completion(shortcut)
                        self.message = "기록되었습니다. ‘이 입력에 적용’을 눌러 장치에 저장하세요."
                    case .failure(let error): self.message = error.localizedDescription
                    }
                }
                return true
            }
            return consumed ? nil : event
        }
    }
}

struct ShortcutRecorderView: View {
    @Binding var shortcut: DeviceShortcut
    @Binding var isRecording: Bool
    let scope: BindingScope
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recorder.isRecording ? "기록 중…" : (shortcut.displayName.isEmpty ? "기록되지 않음" : shortcut.displayName))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("기록된 단축키")
                Button(recorder.isRecording ? "취소" : "단축키 기록") {
                    if recorder.isRecording { recorder.cancel() }
                    else { recorder.begin { shortcut = $0 } }
                }
            }
            Text(recorder.message).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("지원 키 안내") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("보조키 최대 4종 + 일반 키 1개, 총 최대 5개입니다. 보조키만 기록할 수도 있습니다.")
                    Text("보조키: Command · Control · Option · Shift. 왼쪽·오른쪽은 같은 종류로 저장합니다.")
                    Text("기록 가능: A–Z, 0–9, 기호, F1–F20, Enter·Escape·Space·Tab·Backspace, 방향키, Insert·Delete·Home·End·Page Up·Page Down, 숫자 키패드의 숫자·소수점·사칙연산 키.")
                    Text("숫자 키패드 Enter는 일반 Enter로 저장합니다. 한글·영문 입력 문자 대신 키 위치를 기록합니다.")
                    Text("일반 키 여러 개나 순서대로 입력하는 매크로는 지원하지 않습니다. Caps Lock은 직접 선택에서 지정하세요. Fn은 보조키로 저장하지 않으며, 기능 키는 Mac 설정에 따라 Fn과 함께 눌러야 합니다.")
                    Text("밝기·음량·미디어 키, 일부 언어 전용 키와 macOS가 먼저 처리하는 조합은 기록되지 않을 수 있습니다.")
                    Text(scope == .global
                         ? "모든 프로그램: 직접 선택에서는 F21–F24·Print Screen 등 장치 지원 키도 지정할 수 있습니다."
                         : "앱 전용 범위: macOS가 전달할 수 있는 키만 지원합니다. F21–F24·Print Screen 등은 지원하지 않습니다.")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .onChange(of: recorder.isRecording) { isRecording = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in recorder.cancel() }
        .onDisappear { recorder.cancel(); isRecording = false }
    }
}
