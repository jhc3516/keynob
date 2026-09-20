import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import KeynobCore

private let injectedEventMarker: Int64 = 0x4D_50_53_4D_41_43

private struct ForegroundTarget: Equatable {
    let scope: BindingScope
    let processID: pid_t
    let instanceID: String?
}

@MainActor
final class AppRoutingRuntime: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var message = "앱별 동작을 사용하려면 손쉬운 사용 권한이 필요합니다."
    @Published private(set) var actionError: String?
    @Published private(set) var inputDiagnostics: [String] = []

    private func recordDiagnostic(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        inputDiagnostics.append("\(time) · \(message)")
        if inputDiagnostics.count > 12 { inputDiagnostics.removeFirst(inputDiagnostics.count - 12) }
    }

    private let router = MacInputRouter()
    private let dispatcher = InputActionDispatcher()
    private var settings = RoutingSettings()

    func update(settings: RoutingSettings) {
        self.settings = settings
        router.update(settings: settings)
    }

    func requestAccessibilityAndStart() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        guard accessibilityGranted else {
            message = "시스템 설정에서 Keynob의 손쉬운 사용 권한을 켠 뒤 다시 시작하세요."
            return
        }
        do {
            inputDiagnostics = []
            recordDiagnostic("손쉬운 사용: 허용 · 입력 전송 권한: \(CGPreflightPostEventAccess() ? "허용" : "미허용") · 앱별 설정 \(settings.bindings.values.filter { $0.scope != .global }.count)개")
            router.diagnosticHandler = { [weak self] text in self?.recordDiagnostic(text) }
            try router.start(settings: settings) { [weak self] alias, binding, target in
                guard let self else { return }
                self.dispatcher.dispatch(binding, expectedTarget: target) { [weak self] error in
                    self?.actionError = error
                    self?.recordDiagnostic(error.map { "전송 중단: \($0)" }
                        ?? "Layer \(alias.layer) / \(alias.input.label) → macOS에 입력 전송 요청 완료 (대상 앱 수신 여부는 입력칸에서 확인)")
                }
            }
            isRunning = true
            actionError = nil
            message = "ChatGPT·Codex CLI 전용 입력 라우터가 실행 중입니다."
        } catch {
            isRunning = false
            message = error.localizedDescription
        }
    }

    func setShortcutRecording(_ active: Bool) { router.isRecordingShortcut = active }

    func stop() {
        router.stop()
        isRunning = false
        actionError = nil
        message = "앱별 입력 라우터를 중지했습니다."
    }
}

private enum InputRouterError: Error, LocalizedError {
    case accessibilityRequired
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: "손쉬운 사용 권한이 없어 입력 라우터를 시작할 수 없습니다."
        case .tapCreationFailed: "macOS 전역 키 이벤트 감시를 시작하지 못했습니다."
        }
    }
}

private final class MacInputRouter: @unchecked Sendable {
    typealias Handler = @MainActor (MacInputAlias, RoutedBinding, ForegroundTarget) -> Void

    var diagnosticHandler: (@MainActor (String) -> Void)?

    private func diagnose(_ text: String) {
        Task { @MainActor [diagnosticHandler] in diagnosticHandler?(text) }
    }

    var isRecordingShortcut = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: Handler?
    private var settings = RoutingSettings()
    private var suppressedKeyCodes = Set<UInt16>()
    private var lastAcceptedAt: [UInt16: TimeInterval] = [:]

    func update(settings: RoutingSettings) { self.settings = settings }

    func start(settings: RoutingSettings, handler: @escaping Handler) throws {
        guard AXIsProcessTrusted() else { throw InputRouterError.accessibilityRequired }
        stop()
        self.settings = settings
        self.handler = handler
        let mask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MacInputRouter>.fromOpaque(userInfo)
                    .takeUnretainedValue().handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            self.handler = nil
            throw InputRouterError.tapCreationFailed
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        eventTap = nil
        handler = nil
        suppressedKeyCodes.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            diagnose("macOS가 입력 감시를 일시 중지하여 재활성화했습니다.")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if isRecordingShortcut { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == injectedEventMarker {
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let alias = MacInputAliasCatalog.alias(cgKeyCode: code) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            return suppressedKeyCodes.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat, suppressedKeyCodes.contains(code) { return nil }
        let binding = settings.bindings[RoutingSettings.key(layer: alias.layer, input: alias.input)]
        let hasModifiers = matchesAliasModifiers(event.flags)
        // Only report configured alias candidates or exact alias chords; do not record ordinary typing.
        if !hasModifiers {
            if binding?.scope != nil, binding?.scope != .global, code >= 96 {
                diagnose("Layer \(alias.layer) / \(alias.input.label) 후보 키 수신 · 별칭 보조키 불일치 (Control+Shift+Option 필요)")
            }
            return Unmanaged.passUnretained(event)
        }
        let target = ForegroundScopeDetector.currentTarget()
        if !isRepeat {
            let prefix = "Layer \(alias.layer) / \(alias.input.label) 별칭 수신"
            if let binding, binding.scope != .global {
                diagnose("\(prefix) · 설정: \(binding.scope.displayName) · 대상: \(target?.scope.displayName ?? ForegroundScopeDetector.unavailableReason())")
            } else {
                diagnose("\(prefix) · 앱별 설정 없음. 새로 고침 후 저장한 범위를 확인하세요.")
            }
        }
        let decision = AppAliasRoutingDecision.decide(
            binding: binding, hasAliasModifiers: hasModifiers,
            targetScope: target?.scope, isRepeat: isRepeat)
        guard decision != .passThrough else {
            return Unmanaged.passUnretained(event)
        }
        suppressedKeyCodes.insert(code)
        guard decision == .dispatch, let binding, let target else {
            if !isRepeat { diagnose("입력 차단: 설정 범위와 현재 대상 앱·창이 일치하지 않습니다.") }
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - (lastAcceptedAt[code] ?? 0) >= 0.15 {
            lastAcceptedAt[code] = now
            Task { @MainActor [handler] in handler?(alias, binding, target) }
        }
        return nil
    }

    private func matchesAliasModifiers(_ flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand])
        return relevant == [.maskControl, .maskShift, .maskAlternate]
    }
}

@MainActor
private final class InputActionDispatcher {
    func dispatch(
        _ binding: RoutedBinding, expectedTarget: ForegroundTarget,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard expectedTarget.scope != .global else {
            completion("앱별 전달 대상이 아닙니다."); return
        }
        do { _ = try BindingCompiler.validate(binding) }
        catch { completion(error.localizedDescription); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            guard ForegroundScopeDetector.currentTarget() == expectedTarget else {
                completion("전송 직전에 대상 앱·창이 바뀌었거나 대상을 읽지 못했습니다."); return
            }
            guard CGPreflightPostEventAccess() else {
                completion("macOS 입력 전송 권한이 없습니다. 현재 Keynob 앱의 손쉬운 사용 권한을 다시 등록하세요."); return
            }
            if binding.scope == .chatGPT, binding.actionKind == .builtIn,
               binding.builtInActionID == "reasoning_medium" {
                completion("Medium 직접 지정은 지원하지 않습니다. ‘추론 수준 순환’ 또는 모델 선택기에서 직접 선택하세요.")
                return
            }
            if binding.scope == .chatGPT, binding.actionKind == .builtIn,
               let id = binding.builtInActionID, CodexAppKeybindings.commandID(for: id) != nil {
                do {
                    guard NSRunningApplication(processIdentifier: expectedTarget.processID)?.bundleIdentifier == "com.openai.codex" else {
                        throw CodexAppKeybindingError.unsupportedAction
                    }
                    let shortcut = try CodexAppKeybindings().shortcut(for: id)
                    guard ForegroundScopeDetector.currentTarget() == expectedTarget else {
                        completion("단축키를 읽는 동안 대상 앱·창이 바뀌었습니다."); return
                    }
                    self.send(shortcut: shortcut)
                    completion(nil)
                } catch {
                    completion(error.localizedDescription)
                }
                return
            }
            switch binding.actionKind {
            case .disabled: break
            case .shortcut: self.send(shortcut: binding.shortcut)
            case .text: self.send(text: binding.text)
            case .builtIn:
                if let id = binding.builtInActionID { self.sendBuiltIn(id, scope: expectedTarget.scope) }
            }
            completion(nil)
        }
    }

    private func send(shortcut: DeviceShortcut) {
        let modifiers = cgModifiers(shortcut.modifierCodes)
        if let hidCode = shortcut.keyCode, let keyCode = MacKeyCodeCatalog.cgKeyCode(hidCode: hidCode) {
            postKey(keyCode, modifiers: modifiers)
        } else if !shortcut.modifierCodes.isEmpty {
            postModifierChord(shortcut.modifierCodes)
        }
    }

    private func send(text: String) {
        for chunkText in unicodeChunks(text, maximumUTF16Units: 20) {
            let chunk = Array(chunkText.utf16)
            guard let down = CGEvent(keyboardEventSource: eventSource(), virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource(), virtualKey: 0, keyDown: false) else { return }
            down.setIntegerValueField(.eventSourceUserData, value: injectedEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: injectedEventMarker)
            down.flags = []
            up.flags = []
            chunk.withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func unicodeChunks(_ text: String, maximumUTF16Units: Int) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var currentCount = 0
        for scalar in text.unicodeScalars {
            let scalarCount = String(scalar).utf16.count
            if currentCount + scalarCount > maximumUTF16Units, !current.isEmpty {
                result.append(String(current))
                current = String.UnicodeScalarView()
                currentCount = 0
            }
            current.append(scalar)
            currentCount += scalarCount
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    private func sendBuiltIn(_ id: String, scope: BindingScope) {
        if scope == .chatGPT {
            switch id {
            case "enter": postKey(36)
            case "model_menu_up": postKey(126)
            case "model_menu_down": postKey(125)
            case "skills": openCodexURL("codex://skills")
            case "automations": openCodexURL("codex://automations")
            case "copy": postKey(8, modifiers: .maskCommand)
            default: break
            }
            return
        }
        switch id {
        case "resume": send(text: "/resume"); postKey(36)
        case "reasoning_down": postKey(43, modifiers: .maskAlternate)
        case "reasoning_up": postKey(47, modifiers: .maskAlternate)
        case "diagnose": send(text: "현재 문제를 진단하고 원인과 해결책을 제시해줘."); postKey(36)
        case "explain_project": send(text: "이 프로젝트의 구조와 핵심 동작을 설명해줘."); postKey(36)
        case "inspect_docs": send(text: "프로젝트 문서를 점검하고 코드와 다른 부분을 찾아줘."); postKey(36)
        case "copy": postKey(8, modifiers: .maskCommand)
        default: break
        }
    }

    private func openCodexURL(_ value: String) {
        if let url = URL(string: value) { NSWorkspace.shared.open(url) }
    }

    private func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private func postKey(_ code: CGKeyCode, modifiers: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: eventSource(), virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource(), virtualKey: code, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = modifiers
            event.setIntegerValueField(.eventSourceUserData, value: injectedEventMarker)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postModifierChord(_ codes: Set<UInt8>) {
        let ordered: [(UInt8, CGKeyCode, CGEventFlags)] = [
            (0xF1, 59, .maskControl), (0xF2, 56, .maskShift),
            (0xF3, 58, .maskAlternate), (0xF4, 55, .maskCommand)
        ].filter { codes.contains($0.0) }
        var flags: CGEventFlags = []
        for (_, keyCode, flag) in ordered {
            flags.insert(flag)
            postModifier(keyCode, down: true, flags: flags)
        }
        for (_, keyCode, flag) in ordered.reversed() {
            flags.remove(flag)
            postModifier(keyCode, down: false, flags: flags)
        }
    }

    private func postModifier(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: eventSource(), virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: injectedEventMarker)
        event.post(tap: .cghidEventTap)
    }

    private func cgModifiers(_ codes: Set<UInt8>) -> CGEventFlags {
        var flags: CGEventFlags = []
        if codes.contains(0xF1) { flags.insert(.maskControl) }
        if codes.contains(0xF2) { flags.insert(.maskShift) }
        if codes.contains(0xF3) { flags.insert(.maskAlternate) }
        if codes.contains(0xF4) { flags.insert(.maskCommand) }
        return flags
    }
}

private enum ForegroundScopeDetector {
    static func unavailableReason() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "전경 앱을 읽지 못함" }
        guard app.bundleIdentifier == AppTargetPolicy.terminalBundleIdentifier else {
            return "지원 대상 아님 (\(app.bundleIdentifier ?? "알 수 없는 앱"))"
        }
        let title = focusedWindowTitle(pid: app.processIdentifier)
        guard !title.isEmpty else { return "Terminal 창 제목을 읽지 못함" }
        guard let id = AppTargetPolicy.instanceID(fromTerminalWindowTitle: title) else {
            return "전용 CLI 창 제목과 불일치"
        }
        return DedicatedCLIRegistry.shared.contains(instanceID: id)
            ? "전경 창 재확인 필요" : "전용 CLI 등록 없음. Keynob에서 새로 여세요."
    }

    static func currentTarget() -> ForegroundTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if AppTargetPolicy.chatGPTBundleIdentifiers.contains(app.bundleIdentifier ?? "") {
            return ForegroundTarget(scope: .chatGPT, processID: app.processIdentifier, instanceID: nil)
        }
        guard app.bundleIdentifier == AppTargetPolicy.terminalBundleIdentifier else { return nil }
        let title = focusedWindowTitle(pid: app.processIdentifier)
        guard let instanceID = DedicatedCLIRegistry.shared.instanceID(forWindowTitle: title) else { return nil }
        return ForegroundTarget(scope: .codexCLI, processID: app.processIdentifier, instanceID: instanceID)
    }

    private static func focusedWindowTitle(pid: pid_t) -> String {
        let application = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return "" }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return ""
        }
        return title as? String ?? ""
    }
}
