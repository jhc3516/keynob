import Foundation
import XCTest
@testable import MacroPadCore

final class CodexAppKeybindingsTests: XCTestCase {
    func testReasoningActionsUseConfiguredShortcutsInsteadOfDeviceAliases() throws {
        let data = Data("""
        [
          {"command":"composer.decreaseReasoningEffort","key":"Ctrl+Command+Alt+F13"},
          {"command":"composer.increaseReasoningEffort","key":"Ctrl+Command+Alt+F17"},
          {"command":"composer.cycleReasoningEffort","key":"Ctrl+Command+Alt+F16"}
        ]
        """.utf8)
        let down = try CodexAppKeybindings.shortcut(for: "reasoning_down", data: data)
        let up = try CodexAppKeybindings.shortcut(for: "reasoning_up", data: data)
        XCTAssertEqual(down, DeviceShortcut(modifierCodes: [0xF1, 0xF3, 0xF4], keyCode: 0x68))
        XCTAssertEqual(up, DeviceShortcut(modifierCodes: [0xF1, 0xF3, 0xF4], keyCode: 0x6C))
        XCTAssertEqual(MacKeyCodeCatalog.cgKeyCode(hidCode: down.keyCode!), 105)
        XCTAssertEqual(MacKeyCodeCatalog.cgKeyCode(hidCode: up.keyCode!), 64)
        XCTAssertNil(CodexAppKeybindings.commandID(for: "reasoning_medium"))
    }

    func testAcceleratorUsesMacModifiersAndRejectsUnsupportedKeys() {
        XCTAssertEqual(CodexAppKeybindings.parseAccelerator("Control+Option+CmdOrCtrl+Left"),
                       DeviceShortcut(modifierCodes: [0xF1, 0xF3, 0xF4], keyCode: 0x50))
        XCTAssertEqual(CodexAppKeybindings.parseAccelerator("Shift+CommandOrControl+Return"),
                       DeviceShortcut(modifierCodes: [0xF2, 0xF4], keyCode: 0x28))
        for invalid in ["Ctrl+F24", "Ctrl+PrintScreen", "Ctrl+", "Ctrl", "Ctrl+Ctrl+F13",
                        "Ctrl+K Ctrl+C", "Hyper+F13", "Ctrl++", "A+F13", ""] {
            XCTAssertNil(CodexAppKeybindings.parseAccelerator(invalid), invalid)
        }
    }

    func testUnassignedOrExplicitlyDisabledCommandsDoNotFallBackToAliases() {
        for json in ["[]", """
        [{"command":"composer.decreaseReasoningEffort","key":null}]
        """, """
        [{"command":"composer.decreaseReasoningEffort","key":"F13"},
         {"command":"composer.decreaseReasoningEffort","key":null}]
        """] {
            XCTAssertThrowsError(try CodexAppKeybindings.shortcut(for: "reasoning_down", data: Data(json.utf8))) {
                XCTAssertEqual($0 as? CodexAppKeybindingError, .unassignedCommand("composer.decreaseReasoningEffort"))
            }
        }
    }

    func testUsesFirstSupportedAlternativeForSameCommandOnly() throws {
        let data = Data("""
        [{"command":"other.command","key":"F15"},
         {"command":"composer.increaseReasoningEffort","key":"Ctrl+F24"},
         {"command":"composer.increaseReasoningEffort","key":"Option+F18"}]
        """.utf8)
        XCTAssertEqual(try CodexAppKeybindings.shortcut(for: "reasoning_up", data: data),
                       DeviceShortcut(modifierCodes: [0xF3], keyCode: 0x6D))
        XCTAssertThrowsError(try CodexAppKeybindings.shortcut(for: "reasoning_down", data: data))
    }

    func testMalformedKeymapAndUnsupportedActionFailClosed() {
        for json in ["{", "{}", "[{\"command\":4,\"key\":\"F13\"}]", "[{\"command\":\"other.command\"}]"] {
            XCTAssertThrowsError(try CodexAppKeybindings.shortcut(for: "reasoning_down", data: Data(json.utf8))) {
                XCTAssertEqual($0 as? CodexAppKeybindingError, .invalidFile)
            }
        }
        XCTAssertThrowsError(try CodexAppKeybindings.shortcut(for: "copy", data: Data("[]".utf8))) {
            XCTAssertEqual($0 as? CodexAppKeybindingError, .unsupportedAction)
        }
        let unsupported = Data("""
        [{"command":"composer.increaseReasoningEffort","key":"Ctrl+F24"}]
        """.utf8)
        XCTAssertThrowsError(try CodexAppKeybindings.shortcut(for: "reasoning_up", data: unsupported)) {
            XCTAssertEqual($0 as? CodexAppKeybindingError, .unsupportedShortcut("composer.increaseReasoningEffort"))
        }
    }

    func testReadsChangesWithoutRewritingUserFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("keybindings.json")
        let keymap = CodexAppKeybindings(url: url)
        XCTAssertThrowsError(try keymap.shortcut(for: "reasoning_down")) {
            XCTAssertEqual($0 as? CodexAppKeybindingError, .unreadableFile)
        }
        for key in ["F13", "F14"] {
            let data = Data("[{\"command\":\"composer.decreaseReasoningEffort\",\"key\":\"\(key)\"}]".utf8)
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            XCTAssertEqual(try keymap.shortcut(for: "reasoning_down"), CodexAppKeybindings.parseAccelerator(key))
            XCTAssertEqual(try Data(contentsOf: url), data)
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o400)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
