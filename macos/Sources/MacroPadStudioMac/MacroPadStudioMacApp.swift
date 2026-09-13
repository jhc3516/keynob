import AppKit
import MacroPadCore
import SwiftUI

private func restorePersistedLEDOverlay() throws {
    let store = RuntimeLEDOverlayStore()
    guard let state = try store.load(), state.active else { return }
    let hid = MacroPadHID()
    let current = try hid.readLED()
    let target = state.restorationTarget(current: current)
    if let target { _ = try hid.programLED(expected: current, target: target) }
    try store.save(RuntimeLEDOverlayState(active: false, base: target ?? current))
}

private final class MacroPadAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        try? restorePersistedLEDOverlay()
    }
}

@main
struct MacroPadStudioMacApp: App {
    @NSApplicationDelegateAdaptor(MacroPadAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MacroPad Studio", id: "studio") {
            ContentView().frame(minWidth: 1020, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
    }
}

private enum AppResult: Sendable {
    case loaded(FullDeviceSnapshot, RoutingSettings)
    case binding(RoutingConfigurationApplyResult)
    case led(ConfigurationApplyResult)
    case backup(URL)
    case restore(ConfigurationRestoreResult, RoutingSettings)
    case failure(String)
}

private actor RuntimeLEDWriter {
    private let hid = MacroPadHID()
    private let store = RuntimeLEDOverlayStore()

    func show(_ target: LEDSnapshot) throws {
        try Task.checkCancellation()
        let current = try hid.readLED()
        let ownedBase = try store.load()?.restorationTarget(current: current)
        // Preserve both sides until the transaction finishes, including process interruption or HID rollback.
        try store.save(RuntimeLEDOverlayState(
            active: true, base: ownedBase ?? current, overlay: target,
            previousOverlay: ownedBase == nil ? nil : current))
        _ = try hid.programLED(expected: current, target: target)
    }

    func restore() throws {
        try Task.checkCancellation()
        try restorePersistedLEDOverlay()
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct InputTile: View {
    let input: EditableInput
    let title: String
    let detail: String
    let accent: Color
    let isSelected: Bool
    let isEnabled: Bool
    let minimumHeight: CGFloat
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text(title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    if isSelected { Image(systemName: "checkmark.circle.fill") }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? accent : .secondary)
                Text(detail)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected || isFocused ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .help("\(input.label) 선택")
        .accessibilityLabel("\(input.label), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var surfaceColor: Color {
        if isSelected { return accent.opacity(0.16) }
        if isHovered { return Color.primary.opacity(0.09) }
        return Color.primary.opacity(0.045)
    }

    private var borderColor: Color {
        if isSelected || isFocused { return accent }
        if isHovered { return accent.opacity(0.55) }
        return Color.primary.opacity(0.14)
    }
}

private struct KnobPressControl: View {
    let input: EditableInput
    let number: Int
    let detail: String
    let accent: Color
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isSelected ? accent.opacity(0.18) : Color.primary.opacity(isHovered ? 0.1 : 0.05))
                Circle()
                    .strokeBorder(
                        isSelected || isFocused ? accent : Color.primary.opacity(isHovered ? 0.32 : 0.15),
                        lineWidth: isSelected || isFocused ? 3 : 1
                    )
                Circle()
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 7, dash: [2, 7]))
                    .padding(9)
                VStack(spacing: 3) {
                    Text("누름")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isSelected ? accent : .secondary)
                    Text(detail)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .frame(width: 104, height: 104)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .help("Knob \(number) 누름 선택")
        .accessibilityLabel("Knob \(number) 누름, \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MacroPadInputSelector: View {
    let selectedInput: EditableInput
    let isEnabled: Bool
    let detail: (EditableInput) -> String
    let onSelect: (EditableInput) -> Void

    private let keyColumns = Array(repeating: GridItem(.flexible(minimum: 62), spacing: 10), count: 4)
    private var keys: [EditableInput] { Array(EditableInput.all.prefix(12)) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            LazyVGrid(columns: keyColumns, spacing: 10) {
                ForEach(keys) { input in
                    InputTile(
                        input: input,
                        title: input.label,
                        detail: detail(input),
                        accent: .accentColor,
                        isSelected: input == selectedInput,
                        isEnabled: isEnabled,
                        minimumHeight: 72,
                        action: { onSelect(input) }
                    )
                }
            }

            Divider()

            VStack(spacing: 14) {
                knobGroup(number: 1, accent: .teal)
                Divider()
                knobGroup(number: 2, accent: .orange)
            }
            .frame(width: 216)
        }
    }

    @ViewBuilder
    private func knobGroup(number: Int, accent: Color) -> some View {
        let prefix = "knob\(number)_"
        if let press = EditableInput.all.first(where: { $0.id == prefix + "press" }),
           let ccw = EditableInput.all.first(where: { $0.id == prefix + "ccw" }),
           let cw = EditableInput.all.first(where: { $0.id == prefix + "cw" }) {
            VStack(spacing: 9) {
                HStack {
                    Text("KNOB \(number)").font(.caption.weight(.heavy)).foregroundStyle(accent)
                    Spacer()
                    Text("돌리기 · 누르기").font(.caption2).foregroundStyle(.secondary)
                }

                KnobPressControl(
                    input: press,
                    number: number,
                    detail: detail(press),
                    accent: accent,
                    isSelected: press == selectedInput,
                    isEnabled: isEnabled,
                    action: { onSelect(press) }
                )

                HStack(spacing: 8) {
                    InputTile(
                        input: ccw,
                        title: "↺ CCW · 반시계",
                        detail: detail(ccw),
                        accent: accent,
                        isSelected: ccw == selectedInput,
                        isEnabled: isEnabled,
                        minimumHeight: 48,
                        action: { onSelect(ccw) }
                    )
                    InputTile(
                        input: cw,
                        title: "시계 · CW ↻",
                        detail: detail(cw),
                        accent: accent,
                        isSelected: cw == selectedInput,
                        isEnabled: isEnabled,
                        minimumHeight: 48,
                        action: { onSelect(cw) }
                    )
                }
            }
        }
    }
}

private struct ContentView: View {
    @State private var snapshot: FullDeviceSnapshot?
    @State private var routingSettings = RoutingSettings()
    @State private var selectedLayer = 1
    @State private var selectedInput = EditableInput.all[0]
    @State private var binding = RoutedBinding()
    @State private var ledMode: UInt8 = 1
    @State private var ledColors = Array(repeating: LEDPalette.colors[0].value, count: 12)
    @State private var status = "USB 장치를 연결한 뒤 새로 고침을 누르세요."
    @State private var isBusy = false
    @State private var isVisible = false
    @State private var showRestoreConfirmation = false
    @State private var runtimeLEDWriter = RuntimeLEDWriter()
    @State private var statusLEDTask: Task<Void, Never>?
    @StateObject private var appRouting = AppRoutingRuntime()
    @StateObject private var codexStatus = CodexStatusRuntime()
    @StateObject private var terminalLauncher = CodexTerminalLauncher()

    private let service = MacroPadConfigurationService()
    private let settingsStore = RoutingSettingsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            deviceCard
            TabView {
                bindingEditor.tabItem { Label("키 · 노브", systemImage: "keyboard") }
                ledEditor.tabItem { Label("LED", systemImage: "lightbulb") }
                runtimePanel.tabItem { Label("앱 · Codex", systemImage: "app.connected.to.app.below.fill") }
                backupPanel.tabItem { Label("백업", systemImage: "externaldrive") }
            }
            Text("전역·ChatGPT·Codex CLI 범위를 지원합니다. Typeless 범위는 macOS판에 포함하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .onAppear { isVisible = true; codexStatus.start() }
        .onDisappear {
            isVisible = false
            let pendingStatus = statusLEDTask
            pendingStatus?.cancel()
            statusLEDTask = nil
            codexStatus.stop()
            appRouting.stop()
            Task {
                await pendingStatus?.value
                try? await runtimeLEDWriter.restore()
            }
        }
        .onChange(of: selectedLayer) { _ in loadBindingDraft() }
        .onChange(of: selectedInput) { _ in loadBindingDraft() }
        .onChange(of: binding.scope) { newScope in normalizeDraft(for: newScope) }
        .onChange(of: binding.actionKind) { kind in
            if kind == .shortcut { binding.shortcut.disabled = false }
            if kind == .builtIn, !BuiltInActionCatalog.contains(
                id: binding.builtInActionID ?? "", scope: binding.scope) {
                binding.builtInActionID = BuiltInActionCatalog.actions(for: binding.scope).first?.id
            }
        }
        .onChange(of: codexStatus.revision) { _ in updateCodexStatusLED() }
        .alert("현재 연결된 장치에 복원할까요?", isPresented: $showRestoreConfirmation) {
            Button("취소", role: .cancel) {}
            Button("복원", role: .destructive) { restoreBackupConfirmed() }
        } message: {
            Text("이 제품군은 서로 다른 기기도 같은 시리얼을 보고할 수 있습니다. 설정할 장치 한 대만 USB로 연결했는지 확인하세요. 예약 슬롯이 백업과 다르면 복원은 자동으로 중단됩니다.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("MacroPad Studio").font(.largeTitle.bold())
                Text("12키 · 2노브 매크로패드용 macOS 설정 도구").foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button("새로 고침") { runLoad() }.disabled(isBusy)
        }
    }

    private var deviceCard: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: snapshot == nil ? "keyboard" : "keyboard.fill")
                    .font(.system(size: 27)).foregroundStyle(snapshot == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot == nil ? "지원 장치 확인 필요" : "지원 장치 연결됨").font(.headline)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                    if let device = snapshot?.device {
                        Text("VID \(device.vendorID) · PID \(device.productID) · Usage Page \(device.usagePage) · Interface \(device.interfaceNumber)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }.padding(5)
        }
    }

    private var bindingEditor: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("레이어", selection: $selectedLayer) {
                    ForEach(Array(MacroPadIdentity.layerIDs), id: \.self) { Text("Layer \($0)").tag($0) }
                }.pickerStyle(.segmented)
                Text("설정할 키나 노브 동작을 선택하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MacroPadInputSelector(
                    selectedInput: selectedInput,
                    isEnabled: snapshot != nil && !isBusy,
                    detail: bindingLabel,
                    onSelect: { selectedInput = $0 }
                )
            }.frame(minWidth: 540)

            GroupBox("\(selectedInput.label) · Layer \(selectedLayer)") {
                VStack(alignment: .leading, spacing: 13) {
                    Picker("범위", selection: $binding.scope) {
                        ForEach(BindingScope.allCases) { Text($0.displayName).tag($0) }
                    }.frame(maxWidth: 380)
                    Picker("동작", selection: $binding.actionKind) {
                        ForEach(availableActionKinds) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                    Divider()
                    actionEditor
                    Spacer()
                    Text(binding.scope == .global
                         ? "전역 단축키는 매크로패드가 직접 실행하므로 앱이 꺼져도 동작합니다."
                         : "앱별 동작은 손쉬운 사용 권한과 실행 중인 입력 라우터가 필요합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("이 입력에 적용") { applyBinding() }
                        .buttonStyle(.borderedProminent)
                        .disabled(snapshot == nil || isBusy)
                }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.padding(12)
    }

    @ViewBuilder
    private var actionEditor: some View {
        switch binding.actionKind {
        case .disabled:
            Label("이 입력을 비활성화합니다.", systemImage: "nosign").foregroundStyle(.secondary)
        case .shortcut:
            Text("보조키").font(.headline)
            HStack {
                ForEach(DeviceKeyCatalog.modifiers) { modifier in
                    Toggle(modifier.displayName, isOn: modifierBinding(modifier.code)).toggleStyle(.checkbox)
                }
            }
            Text("키").font(.headline)
            Picker("키", selection: regularKeyBinding) {
                Text("보조키만 / 없음").tag(UInt16(0))
                ForEach(availableRegularKeys) { key in
                    Text("\(key.group) · \(key.displayName)").tag(UInt16(key.code))
                }
                if let code = binding.shortcut.keyCode, !availableRegularKeys.contains(where: { $0.code == code }) {
                    Text("\(DeviceKeyCatalog.key(code: code)?.displayName ?? String(code)) · 이 범위에서 지원하지 않음")
                        .tag(UInt16(code))
                }
            }.labelsHidden().frame(maxWidth: 360)
        case .text:
            TextEditor(text: $binding.text)
                .font(.body.monospaced()).frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Label("최대 2,000자입니다. 이 텍스트는 이 Mac의 settings.json에 평문으로 저장됩니다.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .builtIn:
            Picker("내장 동작", selection: builtInBinding) {
                ForEach(BuiltInActionCatalog.actions(for: binding.scope)) { action in
                    Text(action.displayName).tag(Optional(action.id))
                }
            }.frame(maxWidth: 400)
            if binding.scope == .chatGPT,
               let id = binding.builtInActionID, CodexAppKeybindings.commandID(for: id) != nil {
                Text("대상 ChatGPT/Codex 앱에 등록된 추론 수준 단축키를 읽어 사용합니다. 대상 앱의 설정 › 키보드 단축키에 낮추기·높이기가 등록되어 있어야 합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var ledEditor: some View {
        GroupBox("LED 설정") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("모드", selection: $ledMode) {
                    ForEach(0..<6) { Text("Mode \($0)").tag(UInt8($0)) }
                }.frame(width: 180)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
                    ForEach(0..<12, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("KEY \(index + 1)").font(.caption.bold())
                            Picker("KEY \(index + 1)", selection: ledBinding(index)) {
                                ForEach(LEDPalette.colors, id: \.id) { Text($0.label).tag($0.value) }
                            }.labelsHidden()
                            Circle().fill(swiftUIColor(ledColors[index])).frame(width: 20, height: 20)
                        }
                    }
                }
                Spacer()
                HStack {
                    Text("Codex 상태 표시가 끝나면 이 기본 LED 배치로 돌아옵니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("LED 적용") { applyLED() }.buttonStyle(.borderedProminent)
                        .disabled(snapshot == nil || isBusy)
                }
            }.padding(8)
        }.padding(12)
    }

    private var runtimePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("ChatGPT · Codex CLI 입력 라우터") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(appRouting.message, systemImage: appRouting.isRunning ? "checkmark.circle.fill" : "hand.raised")
                        if let error = appRouting.actionError {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        HStack {
                            Button(appRouting.isRunning ? "라우터 다시 시작" : "권한 확인 후 시작") {
                                appRouting.requestAccessibilityAndStart()
                            }
                            Button("중지") { appRouting.stop() }.disabled(!appRouting.isRunning)
                        }
                        Text("시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 권한을 변경한 뒤 앱으로 돌아와 다시 시작하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Codex CLI 전용 실행기") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(terminalLauncher.message)
                        Button("작업 폴더를 골라 Codex CLI 열기") { terminalLauncher.chooseFolderAndLaunch() }
                            .buttonStyle(.borderedProminent)
                        Text("MacroPad Studio가 연 Terminal 창만 Codex CLI 범위로 인식합니다. 첫 실행에는 Terminal 자동화 권한 확인이 나타날 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Codex 상태 LED") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(codexStatus.serverMessage, systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            Text("훅 \(codexStatus.hookHandlerCount)/7").monospacedDigit()
                        }
                        Text(codexStatus.hookMessage).foregroundStyle(.secondary)
                        HStack {
                            Button("설치 / 복구") { codexStatus.installHooks() }
                            Button("이 앱의 훅 제거", role: .destructive) { codexStatus.uninstallHooks() }
                            Button("다시 검사") { codexStatus.inspectHooks() }
                        }
                        Text("설치는 기존 훅을 보존해 7개 이벤트를 병합하고 변경 전 hooks.json 사본을 만듭니다. 설치 후 전용 Codex CLI에서 /hooks를 열어 직접 검토하고 신뢰해야 합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let value = codexStatus.currentStatus {
                            Text("현재 상태: \(statusLabel(value)) · 활성 세션 \(codexStatus.activeSessionCount)개")
                                .font(.callout.bold())
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(12)
        }
    }

    private var backupPanel: some View {
        GroupBox("안전 백업 및 복원") {
            VStack(alignment: .leading, spacing: 14) {
                Label("백업에는 3개 레이어의 75개 원시 보고서, LED 모드와 12개 색상, 장치 식별 정보가 들어갑니다.", systemImage: "checkmark.shield")
                Text(service.backupStore.url.path).font(.caption.monospaced()).textSelection(.enabled)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("지금 백업") { createBackup() }.disabled(snapshot == nil || isBusy)
                    Button("최근 백업 복원") { showRestoreConfirmation = true }.disabled(snapshot == nil || isBusy)
                }
                Text("앱별 라우팅 설정은 \(settingsStore.url.path)에 권한 0600으로 별도 저장됩니다.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
            }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(12)
    }

    private var availableActionKinds: [BindingActionKind] {
        binding.scope == .global ? [.disabled, .shortcut] : BindingActionKind.allCases
    }

    private var availableRegularKeys: [DeviceKey] {
        binding.scope == .global ? DeviceKeyCatalog.regularKeys : MacKeyCodeCatalog.regularKeys
    }

    private var regularKeyBinding: Binding<UInt16> {
        Binding(get: { UInt16(binding.shortcut.keyCode ?? 0) }, set: {
            binding.shortcut.keyCode = $0 == 0 ? nil : UInt8($0)
        })
    }

    private var builtInBinding: Binding<String?> {
        Binding(get: { binding.builtInActionID }, set: { binding.builtInActionID = $0 })
    }

    private func modifierBinding(_ code: UInt8) -> Binding<Bool> {
        Binding(get: { binding.shortcut.modifierCodes.contains(code) }, set: { enabled in
            if enabled { binding.shortcut.modifierCodes.insert(code) }
            else { binding.shortcut.modifierCodes.remove(code) }
        })
    }

    private func ledBinding(_ index: Int) -> Binding<RGBColorValue> {
        Binding(get: { ledColors[index] }, set: { ledColors[index] = $0 })
    }

    private func bindingLabel(for input: EditableInput) -> String {
        guard let report = snapshot?.report(layer: selectedLayer, slot: input.slot) else { return "지원되지 않는 값" }
        let value = BindingCompiler.binding(from: report, layer: selectedLayer, input: input, settings: routingSettings)
        let prefix = value.scope == .global ? "" : value.scope == .chatGPT ? "ChatGPT · " : "CLI · "
        return prefix + value.displayName
    }

    private func loadBindingDraft() {
        guard let report = snapshot?.report(layer: selectedLayer, slot: selectedInput.slot) else {
            binding = RoutedBinding(); return
        }
        binding = BindingCompiler.binding(from: report, layer: selectedLayer, input: selectedInput, settings: routingSettings)
    }

    private func normalizeDraft(for scope: BindingScope) {
        if scope == .global && ![.disabled, .shortcut].contains(binding.actionKind) { binding.actionKind = .shortcut }
        if binding.actionKind == .builtIn,
           !BuiltInActionCatalog.contains(id: binding.builtInActionID ?? "", scope: scope) {
            binding.builtInActionID = BuiltInActionCatalog.actions(for: scope).first?.id
        }
    }

    private func runLoad() {
        perform("장치와 앱 설정을 읽는 중…") {
            try restorePersistedLEDOverlay()
            let device = try service.hid.readFullSnapshot()
            let settings = BindingCompiler.reconciledSettings(try settingsStore.load(), snapshot: device)
            return .loaded(device, settings)
        }
    }

    private func createBackup() {
        perform("전체 장치 백업을 저장하는 중…", restoreBaseLED: true) {
            _ = try service.backupCurrent(); return .backup(service.backupStore.url)
        }
    }

    private func applyBinding() {
        let layer = selectedLayer, input = selectedInput, draft = binding, settings = routingSettings
        guard let expected = snapshot?.report(layer: layer, slot: input.slot) else { return }
        perform("백업 후 \(input.label)을 적용하는 중…", restoreBaseLED: true) {
            .binding(try service.applyRoutedBinding(
                layer: layer, input: input, binding: draft,
                settings: settings, settingsStore: settingsStore, expectedReport: expected))
        }
    }

    private func applyLED() {
        let target = LEDSnapshot(mode: ledMode, colors: ledColors)
        guard let expected = snapshot?.led else { return }
        perform("백업 후 LED 설정을 적용하는 중…", restoreBaseLED: true) {
            .led(try service.applyLED(target, expectedLED: expected))
        }
    }

    private func restoreBackupConfirmed() {
        perform("복구 백업을 만든 뒤 최근 백업을 복원하는 중…", restoreBaseLED: true) {
            let restored = try service.restoreLatestBackup(confirmFamilyDevice: true)
            let settings = BindingCompiler.reconciledSettings(try settingsStore.load(), snapshot: restored.snapshot)
            return .restore(restored, settings)
        }
    }

    private func perform(
        _ message: String,
        restoreBaseLED: Bool = false,
        operation: @escaping @Sendable () throws -> AppResult
    ) {
        let pendingStatus = statusLEDTask
        pendingStatus?.cancel()
        statusLEDTask = nil
        isBusy = true; status = message
        Task {
            await pendingStatus?.value
            let preparationError: String?
            do {
                if restoreBaseLED { try await runtimeLEDWriter.restore() }
                preparationError = nil
            } catch { preparationError = error.localizedDescription }
            let result = if let preparationError {
                AppResult.failure(preparationError)
            } else {
                await Task.detached(priority: .userInitiated) {
                    do { return try operation() }
                    catch { return AppResult.failure(error.localizedDescription) }
                }.value
            }
            isBusy = false
            switch result {
            case .loaded(let value, let settings):
                snapshot = value; routingSettings = settings
                ledMode = value.led.mode; ledColors = value.led.colors
                loadBindingDraft(); appRouting.update(settings: settings)
                status = "3개 레이어, LED와 앱별 라우팅 설정을 읽었습니다."
            case .binding(let value):
                snapshot = value.configuration.snapshot; routingSettings = value.settings
                loadBindingDraft(); appRouting.update(settings: value.settings)
                status = value.configuration.mutation.changed
                    ? "입력 적용과 재검증을 완료했습니다. 백업: \(value.configuration.backupURL.lastPathComponent)"
                    : "장치 별칭은 같고 앱 동작 설정을 갱신했습니다."
            case .led(let value):
                snapshot = value.snapshot; ledMode = value.snapshot.led.mode; ledColors = value.snapshot.led.colors
                status = value.mutation.changed ? "LED 적용과 재검증을 완료했습니다." : "이미 같은 LED 설정입니다."
            case .backup(let url): status = "전체 장치 백업을 저장했습니다: \(url.path)"
            case .restore(let value, let settings):
                snapshot = value.snapshot; routingSettings = settings
                ledMode = value.snapshot.led.mode; ledColors = value.snapshot.led.colors
                loadBindingDraft(); appRouting.update(settings: settings)
                status = "백업 복원 완료 · 슬롯 \(value.changedSlots)개 · 복구 백업: \(value.recoveryBackupURL.lastPathComponent)"
            case .failure(let error): status = error
            }
            if codexStatus.currentStatus != nil { updateCodexStatusLED() }
        }
    }

    private func updateCodexStatusLED() {
        guard isVisible, !isBusy, snapshot != nil, let state = codexStatus.currentStatus else { return }
        let color: RGBColorValue = switch state {
        case .running: RGBColorValue(red: 0, green: 96, blue: 255)
        case .approval: RGBColorValue(red: 255, green: 190, blue: 0)
        case .completed: RGBColorValue(red: 0, green: 220, blue: 80)
        case .error: RGBColorValue(red: 255, green: 30, blue: 30)
        }
        let target = LEDSnapshot(mode: 1, colors: Array(repeating: color, count: 12))
        let revision = codexStatus.revision
        let pendingStatus = statusLEDTask
        pendingStatus?.cancel()
        statusLEDTask = Task {
            await pendingStatus?.value
            guard !Task.isCancelled else { return }
            do {
                try await runtimeLEDWriter.show(target)
            } catch { return }
            if state == .completed && codexStatus.activeSessionCount == 0 {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, codexStatus.revision == revision else { return }
                do {
                    try await runtimeLEDWriter.restore()
                } catch { }
            }
        }
    }

    private func statusLabel(_ value: CodexLEDStatus) -> String {
        switch value {
        case .running: "실행 중"
        case .approval: "승인 대기"
        case .completed: "완료"
        case .error: "오류"
        }
    }

    private func swiftUIColor(_ color: RGBColorValue) -> Color {
        Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
    }
}
