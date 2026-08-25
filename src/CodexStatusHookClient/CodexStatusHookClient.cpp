#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>

namespace {

constexpr size_t kMaxInputBytes = 1024 * 1024;
constexpr wchar_t kPipePath[] = L"\\\\.\\pipe\\CodexKeyboardStudio.Status.v1";
constexpr wchar_t kTestPipeEnvironmentVariable[] = L"CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME";
constexpr wchar_t kTestPipePrefix[] = L"CodexKeyboardStudio.Status.v1.Test.";
constexpr char kInstanceEnvironmentVariable[] = "CODEX_KEYBOARD_INSTANCE_ID";
constexpr char kTestDiagnosticsEnvironmentVariable[] = "CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS";

int HookFailure(int testExitCode) {
    char value[2]{};
    const DWORD length = GetEnvironmentVariableA(
        kTestDiagnosticsEnvironmentVariable,
        value,
        static_cast<DWORD>(sizeof(value)));
    return length == 1 && value[0] == '1' ? testExitCode : 0;
}

std::wstring ResolveStatusPipePath() {
    wchar_t value[129]{};
    const DWORD length = GetEnvironmentVariableW(
        kTestPipeEnvironmentVariable,
        value,
        static_cast<DWORD>(std::size(value)));
    if (length == 0 || length >= std::size(value)) return kPipePath;
    const std::wstring name(value, length);
    const std::wstring prefix(kTestPipePrefix);
    if (name.size() <= prefix.size() || name.compare(0, prefix.size(), prefix) != 0 ||
        !std::all_of(name.begin(), name.end(), [](wchar_t character) {
            return (character >= L'a' && character <= L'z') ||
                (character >= L'A' && character <= L'Z') ||
                (character >= L'0' && character <= L'9') ||
                character == L'.' || character == L'-' || character == L'_';
        })) {
        return kPipePath;
    }
    return L"\\\\.\\pipe\\" + name;
}

bool IsSafeId(const std::string& value) {
    if (value.empty() || value.size() > 128) return false;
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return (character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') ||
            character == '-' || character == '_' || character == '.';
    });
}

bool IsSupportedEvent(const std::string& value) {
    return value == "SessionStart" || value == "UserPromptSubmit" ||
        value == "PreToolUse" || value == "PostToolUse" ||
        value == "PermissionRequest" ||
        value == "Stop" || value == "SessionEnd";
}

void SkipWhitespace(const std::string& json, size_t& position) {
    while (position < json.size() &&
        (json[position] == ' ' || json[position] == '\t' ||
         json[position] == '\r' || json[position] == '\n')) {
        ++position;
    }
}

bool ParseString(const std::string& json, size_t& position, std::string* decoded) {
    if (position >= json.size() || json[position] != '"') return false;
    ++position;
    if (decoded) decoded->clear();
    while (position < json.size()) {
        const unsigned char character = static_cast<unsigned char>(json[position++]);
        if (character == '"') return true;
        if (character < 0x20) return false;
        if (character != '\\') {
            if (decoded) decoded->push_back(static_cast<char>(character));
            continue;
        }
        if (position >= json.size()) return false;
        const char escape = json[position++];
        if (escape == 'u') {
            if (position + 4 > json.size()) return false;
            for (size_t index = 0; index < 4; ++index) {
                const char hex = json[position + index];
                if (!((hex >= '0' && hex <= '9') || (hex >= 'a' && hex <= 'f') ||
                      (hex >= 'A' && hex <= 'F'))) return false;
            }
            position += 4;
            if (decoded) return false;
            continue;
        }
        const char value = escape == '"' ? '"' : escape == '\\' ? '\\' :
            escape == '/' ? '/' : escape == 'b' ? '\b' : escape == 'f' ? '\f' :
            escape == 'n' ? '\n' : escape == 'r' ? '\r' : escape == 't' ? '\t' : '\0';
        if (value == '\0') return false;
        if (decoded) decoded->push_back(value);
    }
    return false;
}

bool ParseLiteral(const std::string& json, size_t& position, const char* literal) {
    const size_t length = std::strlen(literal);
    if (json.compare(position, length, literal) != 0) return false;
    position += length;
    return true;
}

bool SkipValue(const std::string& json, size_t& position, int depth);

bool SkipObject(const std::string& json, size_t& position, int depth) {
    if (depth > 64 || position >= json.size() || json[position++] != '{') return false;
    SkipWhitespace(json, position);
    if (position < json.size() && json[position] == '}') {
        ++position;
        return true;
    }
    while (position < json.size()) {
        if (!ParseString(json, position, nullptr)) return false;
        SkipWhitespace(json, position);
        if (position >= json.size() || json[position++] != ':') return false;
        SkipWhitespace(json, position);
        if (!SkipValue(json, position, depth + 1)) return false;
        SkipWhitespace(json, position);
        if (position < json.size() && json[position] == '}') {
            ++position;
            return true;
        }
        if (position >= json.size() || json[position++] != ',') return false;
        SkipWhitespace(json, position);
    }
    return false;
}

bool SkipArray(const std::string& json, size_t& position, int depth) {
    if (depth > 64 || position >= json.size() || json[position++] != '[') return false;
    SkipWhitespace(json, position);
    if (position < json.size() && json[position] == ']') {
        ++position;
        return true;
    }
    while (position < json.size()) {
        if (!SkipValue(json, position, depth + 1)) return false;
        SkipWhitespace(json, position);
        if (position < json.size() && json[position] == ']') {
            ++position;
            return true;
        }
        if (position >= json.size() || json[position++] != ',') return false;
        SkipWhitespace(json, position);
    }
    return false;
}

bool SkipValue(const std::string& json, size_t& position, int depth) {
    if (depth > 64 || position >= json.size()) return false;
    if (json[position] == '"') return ParseString(json, position, nullptr);
    if (json[position] == '{') return SkipObject(json, position, depth);
    if (json[position] == '[') return SkipArray(json, position, depth);
    if (ParseLiteral(json, position, "true") || ParseLiteral(json, position, "false") ||
        ParseLiteral(json, position, "null")) return true;

    const size_t start = position;
    while (position < json.size() && json[position] != ',' && json[position] != '}' &&
        json[position] != ']' && json[position] != ' ' && json[position] != '\t' &&
        json[position] != '\r' && json[position] != '\n') {
        ++position;
    }
    return position > start;
}

struct ParsedHookInput {
    std::string eventName;
    std::string sessionId;
    std::string turnId;
    bool hasEventName = false;
    bool hasSessionId = false;
    bool hasTurnId = false;
    bool isError = false;
};

bool ParseHookInput(const std::string& json, ParsedHookInput& output) {
    size_t position = 0;
    SkipWhitespace(json, position);
    if (position >= json.size() || json[position++] != '{') return false;
    SkipWhitespace(json, position);
    while (position < json.size() && json[position] != '}') {
        std::string key;
        if (!ParseString(json, position, &key)) return false;
        SkipWhitespace(json, position);
        if (position >= json.size() || json[position++] != ':') return false;
        SkipWhitespace(json, position);

        if (key == "hook_event_name" || key == "session_id" || key == "turn_id") {
            std::string value;
            if (key == "turn_id" && ParseLiteral(json, position, "null")) {
                output.hasTurnId = false;
            } else if (!ParseString(json, position, &value)) {
                return false;
            } else if (key == "hook_event_name") {
                if (output.hasEventName) return false;
                output.eventName = value;
                output.hasEventName = true;
            } else if (key == "session_id") {
                if (output.hasSessionId) return false;
                output.sessionId = value;
                output.hasSessionId = true;
            } else {
                if (output.hasTurnId) return false;
                output.turnId = value;
                output.hasTurnId = true;
            }
        } else if (key == "failed" || key == "success") {
            bool value;
            if (ParseLiteral(json, position, "true")) value = true;
            else if (ParseLiteral(json, position, "false")) value = false;
            else return false;
            if ((key == "failed" && value) || (key == "success" && !value)) output.isError = true;
        } else if (!SkipValue(json, position, 1)) {
            return false;
        }

        SkipWhitespace(json, position);
        if (position < json.size() && json[position] == '}') break;
        if (position >= json.size() || json[position++] != ',') return false;
        SkipWhitespace(json, position);
    }
    if (position >= json.size() || json[position++] != '}') return false;
    SkipWhitespace(json, position);
    return position == json.size() && output.hasEventName && output.hasSessionId;
}

std::string ReadInput() {
    std::string input;
    input.reserve(4096);
    char buffer[4096];
    while (!std::feof(stdin) && input.size() <= kMaxInputBytes) {
        const size_t read = std::fread(buffer, 1, sizeof(buffer), stdin);
        input.append(buffer, read);
        if (std::ferror(stdin)) return {};
    }
    if (input.size() > kMaxInputBytes) return {};
    if (input.size() >= 3 &&
        static_cast<unsigned char>(input[0]) == 0xEF &&
        static_cast<unsigned char>(input[1]) == 0xBB &&
        static_cast<unsigned char>(input[2]) == 0xBF) {
        input.erase(0, 3);
    }
    return input;
}

std::string ReadInstanceId() {
    char value[129]{};
    const DWORD length = GetEnvironmentVariableA(
        kInstanceEnvironmentVariable,
        value,
        static_cast<DWORD>(sizeof(value)));
    if (length == 0 || length >= sizeof(value)) return {};
    const std::string instanceId(value, length);
    return IsSafeId(instanceId) ? instanceId : std::string{};
}

DWORD FindLauncherProcessId() {
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 0;

    std::unordered_map<DWORD, std::pair<DWORD, std::wstring>> processes;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            processes.emplace(
                entry.th32ProcessID,
                std::make_pair(entry.th32ParentProcessID, std::wstring(entry.szExeFile)));
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);

    DWORD processId = GetCurrentProcessId();
    for (int depth = 0; depth < 32; ++depth) {
        const auto current = processes.find(processId);
        if (current == processes.end() || current->second.first == 0 ||
            current->second.first == processId) {
            return 0;
        }
        processId = current->second.first;
        const auto parent = processes.find(processId);
        if (parent == processes.end()) return 0;
        if (_wcsicmp(parent->second.second.c_str(), L"Start-CodexCli.exe") == 0) {
            return processId;
        }
    }
    return 0;
}

}  // namespace

int main() {
    const std::string input = ReadInput();
    ParsedHookInput parsed;
    if (!ParseHookInput(input, parsed)) return HookFailure(10);
    if (!IsSupportedEvent(parsed.eventName)) return HookFailure(14);
    if (!IsSafeId(parsed.sessionId)) return HookFailure(15);
    if (parsed.hasTurnId && !IsSafeId(parsed.turnId)) return HookFailure(16);

    const std::string instanceId = ReadInstanceId();
    const DWORD launcherProcessId = instanceId.empty() ? 0 : FindLauncherProcessId();
    const bool dedicated = !instanceId.empty() && launcherProcessId != 0;
    std::string message = "{\"eventName\":\"" + parsed.eventName +
        "\",\"sessionId\":\"" + parsed.sessionId + "\",\"turnId\":";
    message += parsed.hasTurnId ? "\"" + parsed.turnId + "\"" : "null";
    message += ",\"instanceId\":";
    message += dedicated ? ("\"" + instanceId + "\"") : "null";
    message += ",\"launcherProcessId\":";
    message += launcherProcessId == 0 ? "null" : std::to_string(launcherProcessId);
    message += ",\"sourceKind\":\"";
    message += dedicated ? "dedicated_cli\"" : "unscoped\"";
    message += ",\"producerProcessId\":null";
    message += parsed.isError ? ",\"isError\":true}\n" : ",\"isError\":false}\n";

    const std::wstring pipePath = ResolveStatusPipePath();
    if (!WaitNamedPipeW(pipePath.c_str(), 100)) return HookFailure(11);
    HANDLE pipe = CreateFileW(pipePath.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return HookFailure(12);
    DWORD written = 0;
    const BOOL writeSucceeded = WriteFile(
        pipe,
        message.data(),
        static_cast<DWORD>(message.size()),
        &written,
        nullptr);
    CloseHandle(pipe);
    if (!writeSucceeded || written != static_cast<DWORD>(message.size())) return HookFailure(13);
    return 0;
}
