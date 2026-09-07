import AppKit
import Foundation
import MacroPadCore

final class DedicatedCLIRegistry: @unchecked Sendable {
    static let shared = DedicatedCLIRegistry()

    private let lock = NSLock()
    private var instanceIDs = Set<String>()
    private var timer: Timer?
    private var expirationHandler: (@Sendable (String) -> Void)?

    func register(_ instanceID: String) {
        guard instanceID.hasPrefix("mac-") else { return }
        _ = lock.withLock { instanceIDs.insert(instanceID) }
        DispatchQueue.main.async { [weak self] in self?.startPollingIfNeeded() }
    }

    func contains(instanceID: String) -> Bool {
        lock.withLock { instanceIDs.contains(instanceID) }
    }

    func onExpiration(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { expirationHandler = handler }
    }

    @MainActor
    private func startPollingIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollTerminalTabs()
        }
    }

    private func pollTerminalTabs() {
        let registered = lock.withLock { instanceIDs }
        guard !registered.isEmpty else { return }
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: AppTargetPolicy.terminalBundleIdentifier).isEmpty else {
            expire(registered); return
        }
        let source = """
        set savedDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set collectedTitles to {}
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    set end of collectedTitles to custom title of terminalTab
                end repeat
            end repeat
        end tell
        set resultText to collectedTitles as text
        set AppleScript's text item delimiters to savedDelimiters
        return resultText
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue,
              error == nil else { return }
        let live = Set(result.split(separator: "\n").compactMap {
            AppTargetPolicy.instanceID(fromDedicatedCLITitle: String($0))
        })
        expire(registered.subtracting(live))
    }

    private func expire(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let handler = lock.withLock { () -> (@Sendable (String) -> Void)? in
            instanceIDs.subtract(ids)
            return expirationHandler
        }
        for id in ids { handler?(id) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
