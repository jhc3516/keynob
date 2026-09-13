import Darwin
import Foundation

private let maxInputBytes = 1_048_576
private let supportedEvents = Set([
    "SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse",
    "PostToolUse", "Stop", "SessionEnd"
])

private struct HookInput: Decodable {
    let hookEventName: String
    let sessionID: String
    let turnID: String?
    let isError: Bool?
    let failed: Bool?
    let success: Bool?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case isError = "is_error"
        case failed
        case success
    }
}

private struct StatusMessage: Encodable {
    let eventName: String
    let sessionID: String
    let turnID: String?
    let instanceID: String
    let isError: Bool
}

private func isSafeID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
    }
}

private func statusSocketPath() -> String {
    if let testPath = ProcessInfo.processInfo.environment["KEYNOB_TEST_STATUS_SOCKET"],
       testPath.hasPrefix("/private/tmp/keynob-status-test-"),
       !testPath.contains("..") {
        return testPath
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("MacroPad Studio/status-v1.sock").path
}

private func send(_ data: Data, to path: String) {
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var noSignal: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        path.utf8CString.withUnsafeBytes { source in
            buffer.copyBytes(from: source.prefix(buffer.count))
        }
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { return }
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }
}

private func readBoundedInput() throws -> Data? {
    var result = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: min(8192, maxInputBytes + 1 - result.count)),
          !chunk.isEmpty {
        result.append(chunk)
        if result.count > maxInputBytes { return nil }
    }
    return result
}

guard let inputData = try? readBoundedInput(),
      let input = try? JSONDecoder().decode(HookInput.self, from: inputData),
      supportedEvents.contains(input.hookEventName), isSafeID(input.sessionID),
      input.turnID.map(isSafeID) ?? true,
      let instanceID = ProcessInfo.processInfo.environment["CODEX_KEYBOARD_INSTANCE_ID"],
      instanceID.hasPrefix("mac-"), isSafeID(instanceID) else {
    exit(0)
}
private let message = StatusMessage(
    eventName: input.hookEventName,
    sessionID: input.sessionID,
    turnID: input.turnID,
    instanceID: instanceID,
    isError: input.isError == true || input.failed == true || input.success == false)
private var encodedMessage = try? JSONEncoder().encode(message)
if var encoded = encodedMessage {
    encoded.append(0x0A)
    send(encoded, to: statusSocketPath())
}
