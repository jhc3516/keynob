#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <shobjidl.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cwchar>
#include <filesystem>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr wchar_t kWindowMarker[] = L"Codex CLI - Keynob";
constexpr wchar_t kInstanceEnvironmentVariable[] = L"CODEX_KEYBOARD_INSTANCE_ID";
constexpr wchar_t kDisableTerminalTitleUpdates[] = L"tui.terminal_title=[]";
constexpr wchar_t kPipePath[] = L"\\\\.\\pipe\\CodexKeyboardStudio.Status.v1";
constexpr wchar_t kTestPipeEnvironmentVariable[] = L"CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME";
constexpr wchar_t kTestPipePrefix[] = L"CodexKeyboardStudio.Status.v1.Test.";
constexpr DWORD kTitleGuardIntervalMs = 750;
constexpr DWORD kTitleRestoreDeadlineMs = 2000;

std::string gInstanceId;
std::atomic<bool> gInstanceEndSent{false};

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

bool IsFile(const std::filesystem::path& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

bool IsDirectory(const std::filesystem::path& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

std::optional<std::filesystem::path> SearchEnvironmentPathFor(const wchar_t* fileName) {
    const DWORD required = GetEnvironmentVariableW(L"PATH", nullptr, 0);
    if (required == 0) return std::nullopt;
    std::vector<wchar_t> buffer(static_cast<size_t>(required));
    const DWORD written = GetEnvironmentVariableW(
        L"PATH", buffer.data(), static_cast<DWORD>(buffer.size()));
    if (written == 0 || written >= buffer.size()) return std::nullopt;
    const std::wstring pathValue(buffer.data(), written);
    size_t start = 0;
    while (start <= pathValue.size()) {
        const size_t separator = pathValue.find(L';', start);
        std::wstring directory = pathValue.substr(
            start,
            separator == std::wstring::npos ? std::wstring::npos : separator - start);
        if (directory.size() >= 2 && directory.front() == L'\"' && directory.back() == L'\"') {
            directory = directory.substr(1, directory.size() - 2);
        }
        if (!directory.empty()) {
            const std::filesystem::path candidate =
                std::filesystem::path(directory) / fileName;
            if (IsFile(candidate)) return candidate;
        }
        if (separator == std::wstring::npos) break;
        start = separator + 1;
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> NormalizeDirectory(const std::wstring& input) {
    const DWORD required = GetFullPathNameW(input.c_str(), 0, nullptr, nullptr);
    if (required == 0) return std::nullopt;
    std::vector<wchar_t> buffer(static_cast<size_t>(required) + 1);
    const DWORD written = GetFullPathNameW(
        input.c_str(), static_cast<DWORD>(buffer.size()), buffer.data(), nullptr);
    if (written == 0 || written >= buffer.size()) return std::nullopt;
    std::filesystem::path path(buffer.data());
    return IsDirectory(path) ? std::optional(path) : std::nullopt;
}

std::optional<std::filesystem::path> SelectWorkingDirectory() {
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool shouldUninitialize = SUCCEEDED(initialized);
    IFileOpenDialog* dialog = nullptr;
    HRESULT result = CoCreateInstance(
        CLSID_FileOpenDialog,
        nullptr,
        CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&dialog));
    if (FAILED(result)) {
        if (shouldUninitialize) CoUninitialize();
        return std::nullopt;
    }

    DWORD options = 0;
    result = dialog->GetOptions(&options);
    if (SUCCEEDED(result)) {
        result = dialog->SetOptions(
            options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    }
    if (SUCCEEDED(result)) {
        result = dialog->SetTitle(L"Codex CLI에서 작업할 폴더 선택");
    }
    if (SUCCEEDED(result)) {
        result = dialog->Show(nullptr);
    }

    std::optional<std::filesystem::path> selected;
    if (SUCCEEDED(result)) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(dialog->GetResult(&item))) {
            PWSTR displayName = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &displayName))) {
                selected = NormalizeDirectory(displayName);
                CoTaskMemFree(displayName);
            }
            item->Release();
        }
    }
    dialog->Release();
    if (shouldUninitialize) CoUninitialize();
    return selected;
}

std::optional<std::string> CreateInstanceId() {
    GUID guid{};
    if (FAILED(CoCreateGuid(&guid))) return std::nullopt;
    wchar_t text[40]{};
    if (StringFromGUID2(guid, text, static_cast<int>(std::size(text))) == 0) {
        return std::nullopt;
    }
    std::string id;
    id.reserve(32);
    for (const wchar_t character : text) {
        if ((character >= L'0' && character <= L'9') ||
            (character >= L'a' && character <= L'f')) {
            id.push_back(static_cast<char>(character));
        } else if (character >= L'A' && character <= L'F') {
            id.push_back(static_cast<char>(character - L'A' + 'a'));
        }
    }
    return id.size() == 32 ? std::optional(id) : std::nullopt;
}

std::wstring ToWideAscii(const std::string& value) {
    return std::wstring(value.begin(), value.end());
}

std::wstring QuoteArgument(const std::wstring& argument) {
    std::wstring quoted = L"\"";
    size_t backslashes = 0;
    for (const wchar_t character : argument) {
        if (character == L'\\') {
            ++backslashes;
            continue;
        }
        if (character == L'\"') {
            quoted.append(backslashes * 2 + 1, L'\\');
            quoted.push_back(L'\"');
            backslashes = 0;
            continue;
        }
        quoted.append(backslashes, L'\\');
        backslashes = 0;
        quoted.push_back(character);
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'\"');
    return quoted;
}

std::vector<wchar_t> BuildEnvironment(const std::string& instanceId) {
    std::vector<std::wstring> entries;
    LPWCH raw = GetEnvironmentStringsW();
    if (!raw) return {};
    for (const wchar_t* current = raw; *current != L'\0'; current += std::wcslen(current) + 1) {
        std::wstring entry(current);
        const size_t nameLength = std::size(kInstanceEnvironmentVariable) - 1;
        const bool isInstanceEntry = entry.size() > nameLength &&
            _wcsnicmp(entry.c_str(), kInstanceEnvironmentVariable, nameLength) == 0 &&
            entry[nameLength] == L'=';
        if (!isInstanceEntry) entries.push_back(std::move(entry));
    }
    FreeEnvironmentStringsW(raw);
    entries.push_back(
        std::wstring(kInstanceEnvironmentVariable) + L"=" + ToWideAscii(instanceId));
    std::sort(entries.begin(), entries.end(), [](const auto& left, const auto& right) {
        return _wcsicmp(left.c_str(), right.c_str()) < 0;
    });

    size_t characters = 1;
    for (const auto& entry : entries) characters += entry.size() + 1;
    std::vector<wchar_t> block;
    block.reserve(characters);
    for (const auto& entry : entries) {
        block.insert(block.end(), entry.begin(), entry.end());
        block.push_back(L'\0');
    }
    block.push_back(L'\0');
    return block;
}

class TitleGuard {
public:
    explicit TitleGuard(std::wstring title) : title_(std::move(title)) {
        if (!SetConsoleTitleW(title_.c_str())) {
            throw std::runtime_error("A console title is required for the Codex launcher.");
        }
        stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!stopEvent_) {
            throw std::runtime_error("Could not create the title guard event.");
        }
        try {
            worker_ = std::thread([this] {
                while (WaitForSingleObject(stopEvent_, kTitleGuardIntervalMs) == WAIT_TIMEOUT) {
                    SetConsoleTitleW(title_.c_str());
                }
            });
        } catch (...) {
            CloseHandle(stopEvent_);
            stopEvent_ = nullptr;
            throw;
        }
    }

    TitleGuard(const TitleGuard&) = delete;
    TitleGuard& operator=(const TitleGuard&) = delete;

    ~TitleGuard() {
        if (stopEvent_) SetEvent(stopEvent_);
        if (worker_.joinable()) worker_.join();
        if (stopEvent_) CloseHandle(stopEvent_);
        SetConsoleTitleW(title_.c_str());
    }

private:
    std::wstring title_;
    HANDLE stopEvent_ = nullptr;
    std::thread worker_;
};

std::wstring ReadConsoleTitle() {
    std::vector<wchar_t> buffer(1024);
    const DWORD length = GetConsoleTitleW(buffer.data(), static_cast<DWORD>(buffer.size()));
    return length == 0 ? std::wstring{} : std::wstring(buffer.data(), length);
}

void SendInstanceEnd(bool isError) {
    bool expected = false;
    if (gInstanceId.empty() ||
        !gInstanceEndSent.compare_exchange_strong(expected, true)) {
        return;
    }
    const std::string message =
        "{\"eventName\":\"InstanceEnd\",\"sessionId\":null,\"turnId\":null,"
        "\"instanceId\":\"" + gInstanceId + "\",\"launcherProcessId\":null,"
        "\"sourceKind\":\"dedicated_cli\",\"producerProcessId\":null,\"isError\":" +
        (isError ? "true" : "false") + "}\n";
    const std::wstring pipePath = ResolveStatusPipePath();
    if (!WaitNamedPipeW(pipePath.c_str(), 100)) return;
    const HANDLE pipe = CreateFileW(
        pipePath.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(pipe, message.data(), static_cast<DWORD>(message.size()), &written, nullptr);
    CloseHandle(pipe);
}

BOOL WINAPI ConsoleControlHandler(DWORD controlType) {
    switch (controlType) {
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT:
            return TRUE;
        case CTRL_CLOSE_EVENT:
        case CTRL_LOGOFF_EVENT:
        case CTRL_SHUTDOWN_EVENT:
            SendInstanceEnd(false);
            return TRUE;
        default:
            return FALSE;
    }
}

struct CodexEntryPoint {
    std::filesystem::path codexCommand;
    std::filesystem::path node;
    std::filesystem::path codexJavaScript;
};

std::optional<CodexEntryPoint> FindCodexEntryPoint() {
    const auto codexCommand = SearchEnvironmentPathFor(L"codex.cmd");
    if (!codexCommand) return std::nullopt;
    const auto npmRoot = codexCommand->parent_path();
    const auto codexJavaScript = npmRoot / L"node_modules" / L"@openai" /
        L"codex" / L"bin" / L"codex.js";
    if (!IsFile(codexJavaScript)) return std::nullopt;
    auto node = npmRoot / L"node.exe";
    if (!IsFile(node)) {
        const auto pathNode = SearchEnvironmentPathFor(L"node.exe");
        if (!pathNode) return std::nullopt;
        node = *pathNode;
    }
    return CodexEntryPoint{*codexCommand, node, codexJavaScript};
}

bool IsCompletedExitCode(DWORD exitCode) {
    return exitCode == 0 || exitCode == 130 || exitCode == 0xC000013A;
}

struct Options {
    std::optional<std::wstring> workingDirectory;
    bool validateOnly = false;
    bool validateTitleGuard = false;
};

std::optional<Options> ParseOptions(int argc, wchar_t** argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::wstring argument = argv[index];
        if (argument == L"--working-directory" || argument == L"-WorkingDirectory") {
            if (++index >= argc || options.workingDirectory) return std::nullopt;
            options.workingDirectory = argv[index];
        } else if (argument == L"--validate-only" || argument == L"-ValidateOnly") {
            options.validateOnly = true;
        } else if (argument == L"--validate-title-guard" || argument == L"-ValidateTitleGuard") {
            options.validateTitleGuard = true;
        } else if (!argument.empty() && argument.front() == L'-') {
            return std::nullopt;
        } else if (!options.workingDirectory) {
            options.workingDirectory = argument;
        } else {
            return std::nullopt;
        }
    }
    if (options.validateOnly && options.validateTitleGuard) return std::nullopt;
    return options;
}

int Run(int argc, wchar_t** argv) {
    const auto options = ParseOptions(argc, argv);
    if (!options) {
        std::wcerr << L"Usage: Start-CodexCli.exe [folder] [--working-directory folder] "
                   << L"[--validate-only|--validate-title-guard]\n";
        return 64;
    }

    std::optional<std::filesystem::path> workingDirectory;
    if (options->workingDirectory) {
        workingDirectory = NormalizeDirectory(*options->workingDirectory);
        if (!workingDirectory) {
            std::wcerr << L"Working directory is not a folder: "
                       << *options->workingDirectory << L"\n";
            return 66;
        }
    } else {
        workingDirectory = SelectWorkingDirectory();
        if (!workingDirectory) return 0;
    }

    const auto codex = FindCodexEntryPoint();
    if (!codex) {
        std::wcerr << L"Official npm Codex CLI was not found in PATH.\n";
        return 69;
    }
    const auto instanceId = CreateInstanceId();
    if (!instanceId) {
        std::wcerr << L"Could not create a Codex launcher instance ID.\n";
        return 70;
    }
    gInstanceId = *instanceId;
    const std::wstring title = std::wstring(kWindowMarker) + L" - " + ToWideAscii(*instanceId);

    if (options->validateTitleGuard) {
        TitleGuard guard(title);
        SetConsoleTitleW(L"Codex dynamic title");
        const ULONGLONG deadline = GetTickCount64() + kTitleRestoreDeadlineMs;
        while (GetTickCount64() < deadline && ReadConsoleTitle() != title) {
            Sleep(10);
        }
        if (ReadConsoleTitle() != title) {
            std::wcerr << L"Codex CLI title guard did not restore the marker.\n";
            return 1;
        }
        std::wcout << L"CODEX_TITLE_GUARD_PASS intervalMs=" << kTitleGuardIntervalMs
                   << L" marker=" << title << L"\n";
        return 0;
    }

    if (options->validateOnly) {
        std::wcout << L"CODEX_NATIVE_LAUNCHER_READY titleGuardMs="
                   << kTitleGuardIntervalMs
                   << L" terminalTitleUpdates=False"
                   << L" instanceIdFormat=guidN shell=False workingDirectory="
                   << workingDirectory->wstring() << L"\n";
        return 0;
    }

    const std::vector<std::wstring> arguments = {
        codex->node.wstring(), codex->codexJavaScript.wstring(),
        L"--config", kDisableTerminalTitleUpdates,
        L"-C", workingDirectory->wstring()
    };
    std::wstring commandLine;
    for (const auto& argument : arguments) {
        if (!commandLine.empty()) commandLine.push_back(L' ');
        commandLine += QuoteArgument(argument);
    }
    std::vector<wchar_t> mutableCommandLine(commandLine.begin(), commandLine.end());
    mutableCommandLine.push_back(L'\0');
    auto environment = BuildEnvironment(*instanceId);
    if (environment.empty()) {
        std::wcerr << L"Could not create the Codex environment block.\n";
        return 70;
    }

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    TitleGuard titleGuard(title);
    if (!SetConsoleCtrlHandler(ConsoleControlHandler, TRUE)) {
        std::wcerr << L"Could not register the console control handler. win32="
                   << GetLastError() << L"\n";
        return 71;
    }
    const BOOL created = CreateProcessW(
        codex->node.c_str(),
        mutableCommandLine.data(),
        nullptr,
        nullptr,
        TRUE,
        CREATE_UNICODE_ENVIRONMENT,
        environment.data(),
        workingDirectory->c_str(),
        &startup,
        &process);
    if (!created) {
        SetConsoleCtrlHandler(ConsoleControlHandler, FALSE);
        std::wcerr << L"Could not start Codex CLI. win32=" << GetLastError() << L"\n";
        return 71;
    }
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hProcess);
    SendInstanceEnd(!IsCompletedExitCode(exitCode));
    SetConsoleCtrlHandler(ConsoleControlHandler, FALSE);
    return static_cast<int>(exitCode);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    try {
        return Run(argc, argv);
    } catch (const std::exception& exception) {
        std::cerr << "Codex launcher failed: " << exception.what() << "\n";
        return 1;
    } catch (...) {
        std::cerr << "Codex launcher failed with an unknown error.\n";
        return 1;
    }
}
