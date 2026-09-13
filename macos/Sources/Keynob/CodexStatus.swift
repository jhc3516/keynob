import Combine
import Darwin
import Foundation
import KeynobCore

private let codexHookEvents = CodexHookConfiguration.eventNames

struct CodexStatusEvent: Codable, Sendable {
    let eventName: String
    let sessionID: String
    let turnID: String?
    let instanceID: String
    let isError: Bool
}

typealias CodexLEDStatus = CodexLifecycleStatus

@MainActor
final class CodexStatusRuntime: ObservableObject {
    @Published private(set) var currentStatus: CodexLEDStatus?
    @Published private(set) var activeSessionCount = 0
    @Published private(set) var revision = 0
    @Published private(set) var serverMessage = "상태 수신기 중지됨"
    @Published private(set) var hookMessage = "Codex 상태 훅 설치 필요"
    @Published private(set) var hookHandlerCount = 0

    private let server = CodexStatusSocketServer()
    private let installer = CodexHookInstaller()
    private var aggregator = CodexStatusAggregator()

    func start() {
        DedicatedCLIRegistry.shared.onExpiration { [weak self] instanceID in
            Task { @MainActor in self?.retire(instanceID: instanceID) }
        }
        do {
            try server.start { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
            serverMessage = "전용 Codex CLI 상태 수신 중"
        } catch {
            serverMessage = error.localizedDescription
        }
        inspectHooks()
    }

    func stop() { server.stop() }

    func inspectHooks() {
        let inspection = installer.inspect()
        hookHandlerCount = inspection.handlerCount
        hookMessage = inspection.message
    }

    func installHooks() {
        do {
            _ = try installer.install()
            inspectHooks()
        } catch {
            hookHandlerCount = installer.inspect().handlerCount
            hookMessage = error.localizedDescription
        }
    }

    func uninstallHooks() {
        do {
            _ = try installer.uninstall()
            inspectHooks()
        } catch {
            hookHandlerCount = installer.inspect().handlerCount
            hookMessage = error.localizedDescription
        }
    }

    private func apply(_ event: CodexStatusEvent) {
        guard codexHookEvents.contains(event.eventName), isSafeID(event.sessionID),
              isSafeID(event.instanceID), event.instanceID.hasPrefix("mac-"),
              DedicatedCLIRegistry.shared.contains(instanceID: event.instanceID),
              event.turnID.map(isSafeID) ?? true else { return }
        publish(aggregator.apply(CodexLifecycleEvent(
            eventName: event.eventName, sessionID: event.sessionID,
            turnID: event.turnID, instanceID: event.instanceID, isError: event.isError)))
    }

    private func retire(instanceID: String) {
        publish(aggregator.retire(instanceID: instanceID))
    }

    private func publish(_ aggregate: CodexLifecycleAggregate) {
        currentStatus = aggregate.status
        activeSessionCount = aggregate.activeSessionCount
        if aggregate.changed { revision += 1 }
    }
}

private func isSafeID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
    }
}

private enum CodexStatusError: Error, LocalizedError {
    case socketPathTooLong
    case socketFailure(String)
    case packagedHelperMissing
    case invalidHooks

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong: "Codex 상태 소켓 경로가 너무 깁니다."
        case .socketFailure(let reason): "Codex 상태 수신기 오류: \(reason)"
        case .packagedHelperMissing: "앱 번들에 Codex 상태 훅 클라이언트가 없습니다."
        case .invalidHooks: "기존 hooks.json 구조가 올바르지 않아 변경하지 않았습니다."
        }
    }
}

private final class CodexStatusSocketServer: @unchecked Sendable {
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.github.jhc3516.keynob.status")

    private var socketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MacroPad Studio/status-v1.sock")
    }

    func start(handler: @escaping @Sendable (CodexStatusEvent) -> Void) throws {
        try queue.sync { try startOnQueue(handler: handler) }
    }

    private func startOnQueue(handler: @escaping @Sendable (CodexStatusEvent) -> Void) throws {
        stopOnQueue()
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw CodexStatusError.socketPathTooLong
        }
        _ = unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexStatusError.socketFailure(String(cString: strerror(errno))) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let reason = String(cString: strerror(errno)); close(fd)
            throw CodexStatusError.socketFailure(reason)
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyBytes(from: $0.prefix(buffer.count)) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno)); close(fd)
            if bound == 0 { _ = unlink(path) }
            throw CodexStatusError.socketFailure(reason)
        }
        chmod(path, S_IRUSR | S_IWUSR)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptAvailable(listener: fd, handler: handler) }
        readSource.setCancelHandler { close(fd) }
        source = readSource
        readSource.resume()
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        _ = unlink(socketURL.path)
    }

    private func acceptAvailable(listener: Int32, handler: @Sendable (CodexStatusEvent) -> Void) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else { return }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while data.count <= 16_384 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            var readiness = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return }
            let count = Darwin.read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.last == 0x0A { break }
        }
        guard data.count <= 16_384,
              let event = try? JSONDecoder().decode(CodexStatusEvent.self, from: data) else { return }
        handler(event)
    }
}

private struct CodexHookInspection {
    let handlerCount: Int
    let message: String
}

private struct CodexHookInstaller {
    private var codexDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
    private var hooksURL: URL { codexDirectory.appendingPathComponent("hooks.json") }
    private var helperURL: URL { codexDirectory.appendingPathComponent("macropad-status-hook") }
    private var packagedHelperURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("keynob-status-hook")
    }

    func inspect() -> CodexHookInspection {
        guard FileManager.default.fileExists(atPath: helperURL.path),
              let data = try? Data(contentsOf: hooksURL),
              let count = try? CodexHookConfiguration.ownedHandlerCount(
                data: data, command: helperURL.path) else {
            return CodexHookInspection(handlerCount: 0, message: "Codex 상태 훅 설치 필요")
        }
        return count == codexHookEvents.count
            ? CodexHookInspection(handlerCount: count, message: "설치 정상 · Codex CLI에서 /hooks 신뢰 확인 필요")
            : CodexHookInspection(handlerCount: count, message: "설치 불완전 · 설치/복구 필요")
    }

    func install() throws -> String {
        guard let packaged = packagedHelperURL,
              FileManager.default.fileExists(atPath: packaged.path) else {
            throw CodexStatusError.packagedHelperMissing
        }
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let current = FileManager.default.fileExists(atPath: hooksURL.path)
            ? try Data(contentsOf: hooksURL) : nil
        let updated = try CodexHookConfiguration.merged(
            data: current, command: helperURL.path, install: true)
        try backupHooksIfPresent()
        try copyHelper(from: packaged)
        try writeHooks(updated)
        return "Codex 상태 훅 7개를 설치했습니다. 전용 CLI에서 /hooks를 열어 신뢰하세요."
    }

    func uninstall() throws -> String {
        let current = FileManager.default.fileExists(atPath: hooksURL.path)
            ? try Data(contentsOf: hooksURL) : nil
        let updated = try CodexHookConfiguration.merged(
            data: current, command: helperURL.path, install: false)
        try backupHooksIfPresent()
        try writeHooks(updated)
        if FileManager.default.fileExists(atPath: helperURL.path) { try FileManager.default.removeItem(at: helperURL) }
        return "이 앱의 Codex 상태 훅 7개를 제거했습니다."
    }

    private func copyHelper(from source: URL) throws {
        let temporary = helperURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        guard rename(temporary.path, helperURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeHooks(_ data: Data) throws {
        try data.write(to: hooksURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooksURL.path)
    }

    private func backupHooksIfPresent() throws {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return }
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = codexDirectory.appendingPathComponent("hooks.json.keynob-backup-\(stamp)")
        try FileManager.default.copyItem(at: hooksURL, to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
}
