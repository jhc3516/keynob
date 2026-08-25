#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>

using hid_device = void;

struct hid_device_info {
    char* path;
    unsigned short vendor_id;
    unsigned short product_id;
    wchar_t* serial_number;
    unsigned short release_number;
    wchar_t* manufacturer_string;
    wchar_t* product_string;
    unsigned short usage_page;
    unsigned short usage;
    int interface_number;
    hid_device_info* next;
};

using hid_init_fn = int(__cdecl*)();
using hid_exit_fn = int(__cdecl*)();
using hid_enumerate_fn = hid_device_info*(__cdecl*)(unsigned short, unsigned short);
using hid_free_enumeration_fn = void(__cdecl*)(hid_device_info*);
using hid_open_path_fn = hid_device*(__cdecl*)(const char*);
using hid_write_fn = int(__cdecl*)(hid_device*, const unsigned char*, size_t);
using hid_read_timeout_fn = int(__cdecl*)(hid_device*, unsigned char*, size_t, int);
using hid_close_fn = void(__cdecl*)(hid_device*);

namespace {

constexpr unsigned short kVendorId = 0x514c;
constexpr unsigned short kProductId = 0x8850;
constexpr unsigned short kUsagePage = 0xff00;
constexpr int kInterfaceNumber = 0;
constexpr int kSlotCount = 25;
constexpr int kColorSlotOffsets[] = {5, 8, 11, 14, 17, 20, 23, 26, 29, 32, 35, 38};
struct AliasDefinition {
    const char* inputId;
    int slot;
    unsigned char keyCode;
};

constexpr AliasDefinition kAliases[] = {
    {"key01", 1, 0x3a}, {"key02", 2, 0x3b}, {"key03", 3, 0x3c},
    {"key04", 4, 0x3d}, {"key05", 5, 0x3e}, {"key06", 6, 0x3f},
    {"key07", 7, 0x40}, {"key08", 8, 0x41}, {"key09", 9, 0x42},
    {"key10", 10, 0x43}, {"key11", 11, 0x44}, {"key12", 12, 0x45},
    {"knob1_ccw", 16, 0x50}, {"knob1_press", 17, 0x28}, {"knob1_cw", 18, 0x4f},
    {"knob2_ccw", 19, 0x52}, {"knob2_press", 20, 0x10}, {"knob2_cw", 21, 0x51}
};
constexpr const char* kRgbReports[] = {
    "03feb000010000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ffff0000ffff0000ffff0000ff000000000000000000000000",
    "03feb00100ff0000ff8030ffff3000ff0000ffff0000ff8000808b0000ffa500ffff967dff00008b8b00008bff00ffff6666ffc864000000000000000000000000",
    "03feb00200ff0000ff8030ffff3000ff0000ffff0000ff8000808b0000ffa500ffff967dff00008b8b00008bff00ffff6666ffc864000000000000000000000000"
};

struct TargetSelection {
    int count{};
    std::string path;
    std::wstring serial;
};

TargetSelection SelectTarget(hid_device_info* devices) {
    TargetSelection selection;
    for (hid_device_info* current = devices; current; current = current->next) {
        if (current->vendor_id != kVendorId || current->product_id != kProductId ||
            current->interface_number != kInterfaceNumber ||
            current->usage_page != kUsagePage || !current->path) {
            continue;
        }
        ++selection.count;
        if (selection.count == 1) {
            selection.path = current->path;
            selection.serial = current->serial_number ? current->serial_number : L"";
        }
    }
    return selection;
}

template <typename T>
T Load(HMODULE module, const char* name) {
    return reinterpret_cast<T>(GetProcAddress(module, name));
}

std::string SiblingDllPath() {
    std::array<char, MAX_PATH> path{};
    if (!GetModuleFileNameA(nullptr, path.data(), static_cast<DWORD>(path.size()))) {
        return {};
    }
    std::string result(path.data());
    const size_t slash = result.find_last_of("\\/");
    if (slash == std::string::npos) {
        return {};
    }
    result.resize(slash + 1);
    result += "hidapi.dll";
    return result;
}

void PrintError(const char* error, int code) {
    std::printf("{\"ok\":false,\"connected\":false,\"error\":\"%s\",\"code\":%d}\n", error, code);
}

void PrintHex(const unsigned char* data, size_t length) {
    for (size_t index = 0; index < length; ++index) {
        std::printf("%02x", data[index]);
    }
}

bool HexByte(const char* value, unsigned char& output) {
    const auto nibble = [](char character) -> int {
        if (character >= '0' && character <= '9') return character - '0';
        if (character >= 'a' && character <= 'f') return character - 'a' + 10;
        if (character >= 'A' && character <= 'F') return character - 'A' + 10;
        return -1;
    };
    const int high = nibble(value[0]);
    const int low = nibble(value[1]);
    if (high < 0 || low < 0) {
        return false;
    }
    output = static_cast<unsigned char>((high << 4) | low);
    return true;
}

bool GetStatusColor(const char* name, std::array<unsigned char, 3>& color) {
    if (std::strcmp(name, "blue") == 0) color = {0x00, 0x00, 0xff};
    else if (std::strcmp(name, "yellow") == 0) color = {0xff, 0xff, 0x3c};
    else if (std::strcmp(name, "green") == 0) color = {0x00, 0xff, 0x00};
    else if (std::strcmp(name, "red") == 0) color = {0xff, 0x00, 0x00};
    else if (std::strcmp(name, "orange") == 0) color = {0xff, 0x80, 0x30};
    else if (std::strcmp(name, "cyan") == 0) color = {0x00, 0xff, 0xff};
    else if (std::strcmp(name, "purple") == 0) color = {0x80, 0x00, 0x80};
    else if (std::strcmp(name, "pink") == 0) color = {0xff, 0x66, 0x66};
    else return false;
    return true;
}

bool BuildLedReport(
    int reportIndex,
    const std::array<std::array<unsigned char, 3>, 12>& colors,
    std::array<unsigned char, 65>& report,
    unsigned char mode = 1) {
    if (reportIndex < 0 || reportIndex >= 3) return false;
    for (size_t index = 0; index < report.size(); ++index) {
        if (!HexByte(kRgbReports[reportIndex] + index * 2, report[index])) return false;
    }
    if (reportIndex == 0) {
        report[4] = mode;
        for (size_t colorIndex = 0; colorIndex < colors.size(); ++colorIndex) {
            std::memcpy(
                report.data() + kColorSlotOffsets[colorIndex],
                colors[colorIndex].data(),
                colors[colorIndex].size());
        }
    }
    return true;
}

bool ReadLedState(
    hid_device* device,
    hid_write_fn hidWrite,
    hid_read_timeout_fn hidReadTimeout,
    std::array<unsigned char, 64>& currentRgb) {
    std::array<unsigned char, 65> request{};
    request[0] = 0x03;
    request[1] = 0xfa;
    request[2] = 0xb0;
    if (hidWrite(device, request.data(), request.size()) !=
        static_cast<int>(request.size())) {
        return false;
    }

    const int read = hidReadTimeout(
        device, currentRgb.data(), currentRgb.size(), 1500);
    return read == static_cast<int>(currentRgb.size()) &&
        currentRgb[0] == 0x03 && currentRgb[1] == 0xfa && currentRgb[2] <= 0x05;
}

bool LedStateMatches(
    const std::array<unsigned char, 64>& currentRgb,
    const std::array<std::array<unsigned char, 3>, 12>& colors,
    unsigned char mode = 1) {
    if (currentRgb[2] != mode) return false;
    for (size_t colorIndex = 0; colorIndex < colors.size(); ++colorIndex) {
        const size_t responseOffset = static_cast<size_t>(kColorSlotOffsets[colorIndex] - 2);
        if (std::memcmp(
                currentRgb.data() + responseOffset,
                colors[colorIndex].data(),
                colors[colorIndex].size()) != 0) {
            return false;
        }
    }
    return true;
}

bool ParseHexReport(const char* text, std::array<unsigned char, 64>& report) {
    if (!text || std::strlen(text) != report.size() * 2) {
        return false;
    }
    for (size_t index = 0; index < report.size(); ++index) {
        if (!HexByte(text + index * 2, report[index])) {
            return false;
        }
    }
    return true;
}

const AliasDefinition* FindAlias(const char* inputId) {
    for (const auto& alias : kAliases) {
        if (std::strcmp(alias.inputId, inputId) == 0) {
            return &alias;
        }
    }
    return nullptr;
}

std::array<unsigned char, 64> BuildAliasReport(const AliasDefinition& alias) {
    std::array<unsigned char, 64> report{};
    report[0] = 0x03;
    report[1] = 0xfa;
    report[2] = static_cast<unsigned char>(alias.slot);
    report[3] = 0x01;
    report[4] = 0x01;
    report[5] = 0x00;

    // Typeless records every raw key it sees, so KEY 4 must contain only the
    // requested modifiers rather than an application interception alias.
    if (std::strcmp(alias.inputId, "key04") == 0) {
        report[6] = 0x03;
        report[9] = 0xf1;   // Control
        report[12] = 0xf4;  // Windows
        report[15] = 0xf3;  // Alt
        for (int separator = 11; separator <= 59; separator += 3) {
            report[separator] = 0x32;
        }
        return report;
    }

    report[6] = 0x04;
    report[9] = 0xf1;   // Control
    report[12] = 0xf2;  // Shift
    report[15] = 0xf3;  // Alt
    report[18] = alias.keyCode;
    return report;
}

bool IsAllowedRegularKey(unsigned char code) {
    return (code >= 0x04 && code <= 0x31) ||
        (code >= 0x33 && code <= 0x57) ||
        (code >= 0x59 && code <= 0x63) ||
        code == 0x65 ||
        (code >= 0x68 && code <= 0x73);
}

void PrintJsonString(const std::wstring& value) {
    const int length = value.empty() ? 0 : WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
        nullptr, 0, nullptr, nullptr);
    std::string utf8(length > 0 ? static_cast<size_t>(length) : 0, '\0');
    if (length > 0) {
        WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
            static_cast<int>(value.size()), utf8.data(), length, nullptr, nullptr);
    }
    std::putchar('"');
    for (const unsigned char character : utf8) {
        if (character == '"' || character == '\\') std::putchar('\\');
        if (character >= 0x20) std::putchar(character);
        else std::printf("\\u%04x", character);
    }
    std::putchar('"');
}

bool TryParseLayer(const char* value, int& layer) {
    if (std::strcmp(value, "1") == 0 || std::strcmp(value, "2") == 0 ||
        std::strcmp(value, "3") == 0) {
        layer = value[0] - '0';
        return true;
    }
    return false;
}

bool ValidateReplacementReport(
    const std::array<unsigned char, 64>& report,
    int expectedLayer,
    int expectedSlot) {
    if (report[0] != 0x03 || report[1] != 0xfa ||
        report[2] != static_cast<unsigned char>(expectedSlot) ||
        report[3] != static_cast<unsigned char>(expectedLayer) ||
        report[4] != 0x01 || report[5] != 0x00 ||
        report[7] != 0x00 || report[8] != 0x00) {
        return false;
    }
    const int count = report[6];
    if (count < 1 || count > 5) return false;

    int regularKeyCount = 0;
    std::array<bool, 256> seen{};
    for (int index = 0; index < 17; ++index) {
        const int offset = 9 + index * 3;
        const unsigned char code = report[offset];
        if (report[offset + 1] != 0x00 ||
            (report[offset + 2] != 0x00 && report[offset + 2] != 0x32)) {
            return false;
        }
        if (index >= count) {
            if (code != 0x00) return false;
            continue;
        }
        if (code == 0x00) {
            if (count != 1 || index != 0) return false;
            continue;
        }
        if (seen[code]) return false;
        seen[code] = true;
        if (code >= 0xf1 && code <= 0xf4) continue;
        if (!IsAllowedRegularKey(code) || ++regularKeyCount > 1) return false;
    }
    return report[60] == 0x00 && report[61] == 0x00 &&
        report[62] == 0x00 && report[63] == 0x00;
}

bool ValidateCurrentReport(
    const std::array<unsigned char, 64>& report,
    int expectedLayer,
    int expectedSlot) {
    if (report[5] > 0x01) return false;
    auto normalized = report;
    normalized[5] = 0x00;
    return ValidateReplacementReport(normalized, expectedLayer, expectedSlot);
}

bool MatchesLayerSlotHeader(
    const std::array<unsigned char, 64>& report,
    int expectedLayer,
    int expectedSlot) {
    return report[0] == 0x03 && report[1] == 0xfa &&
        report[2] == static_cast<unsigned char>(expectedSlot) &&
        report[3] == static_cast<unsigned char>(expectedLayer);
}

bool RunKeyCatalogSelfTest() {
    const std::array<unsigned char, 32> newlyAllowed{
        0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35,
        0x36, 0x37, 0x38, 0x39, 0x46, 0x47, 0x48, 0x53,
        0x54, 0x55, 0x56, 0x57, 0x59, 0x5a, 0x5b, 0x5c,
        0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x65
    };
    const std::array<unsigned char, 6> rejected{
        0x32, 0x58, 0x64, 0x66, 0x67, 0xe9
    };

    auto validateCode = [](unsigned char code) {
        for (int layer = 1; layer <= 3; ++layer) {
            std::array<unsigned char, 64> report{};
            report[0] = 0x03;
            report[1] = 0xfa;
            report[2] = 0x01;
            report[3] = static_cast<unsigned char>(layer);
            report[4] = 0x01;
            report[6] = 0x01;
            report[9] = code;
            for (int separator = 11; separator <= 59; separator += 3) {
                report[separator] = 0x32;
            }
            if (!ValidateReplacementReport(report, layer, 1) ||
                ValidateReplacementReport(report, layer == 3 ? 2 : layer + 1, 1)) {
                return false;
            }
        }
        return true;
    };

    return std::all_of(newlyAllowed.begin(), newlyAllowed.end(), validateCode) &&
        std::none_of(rejected.begin(), rejected.end(), validateCode);
}

bool ReadLayer(
    hid_device* device,
    hid_write_fn hidWrite,
    hid_read_timeout_fn hidReadTimeout,
    int layer,
    std::array<std::array<unsigned char, 64>, kSlotCount + 1>& slots) {
    std::array<unsigned char, 65> request{};
    request[0] = 0x03;
    request[1] = 0xfa;
    request[2] = 0x19;
    request[3] = 0x00;
    request[4] = static_cast<unsigned char>(layer);
    if (hidWrite(device, request.data(), request.size()) != static_cast<int>(request.size())) {
        return false;
    }

    std::array<bool, kSlotCount + 1> seen{};
    for (int index = 0; index < kSlotCount; ++index) {
        std::array<unsigned char, 64> response{};
        const int bytesRead = hidReadTimeout(device, response.data(), response.size(), 1500);
        const int slot = response[2];
        if (bytesRead != static_cast<int>(response.size()) ||
            response[0] != 0x03 || response[1] != 0xfa ||
            response[3] != static_cast<unsigned char>(layer) ||
            slot < 1 || slot > kSlotCount || seen[slot]) {
            return false;
        }
        seen[slot] = true;
        slots[slot] = response;
    }
    return true;
}

std::array<std::array<unsigned char, 3>, 12> GetLedColors(
    const std::array<unsigned char, 64>& currentRgb) {
    std::array<std::array<unsigned char, 3>, 12> colors{};
    for (size_t index = 0; index < colors.size(); ++index) {
        std::memcpy(colors[index].data(), currentRgb.data() + 3 + index * 3, 3);
    }
    return colors;
}

int WriteLedReports(
    hid_device* device,
    hid_write_fn hidWrite,
    unsigned char mode,
    const std::array<std::array<unsigned char, 3>, 12>& colors,
    DWORD settleDelayMs = 2) {
    int written = 0;
    for (int reportIndex = 0; reportIndex < 3; ++reportIndex) {
        std::array<unsigned char, 65> report{};
        if (!BuildLedReport(reportIndex, colors, report, mode) ||
            hidWrite(device, report.data(), report.size()) != static_cast<int>(report.size())) {
            break;
        }
        ++written;
        if (settleDelayMs > 0) Sleep(settleDelayMs);
    }
    return written;
}

struct LedTransactionResult {
    bool succeeded;
    int reportsWritten;
    bool restoreAttempted;
    bool restoreVerified;
};

LedTransactionResult ApplyLedTransaction(
    hid_device* device,
    hid_write_fn hidWrite,
    hid_read_timeout_fn hidReadTimeout,
    const std::array<unsigned char, 64>& original,
    unsigned char targetMode,
    const std::array<std::array<unsigned char, 3>, 12>& targetColors,
    DWORD settleDelayMs = 2) {
    if (LedStateMatches(original, targetColors, targetMode)) return {true, 0, false, true};

    int written = WriteLedReports(device, hidWrite, targetMode, targetColors, settleDelayMs);
    if (written == 3 && settleDelayMs > 0) Sleep(5);
    std::array<unsigned char, 64> verification{};
    if (written == 3 && ReadLedState(device, hidWrite, hidReadTimeout, verification) &&
        LedStateMatches(verification, targetColors, targetMode)) {
        return {true, written, false, true};
    }

    const auto originalColors = GetLedColors(original);
    written += WriteLedReports(device, hidWrite, original[2], originalColors, settleDelayMs);
    if (settleDelayMs > 0) Sleep(5);
    std::array<unsigned char, 64> restored{};
    const bool restoredOk = ReadLedState(device, hidWrite, hidReadTimeout, restored) &&
        LedStateMatches(restored, originalColors, original[2]);
    return {false, written, true, restoredOk};
}

bool ParseLedColors(
    const char* text,
    std::array<std::array<unsigned char, 3>, 12>& colors) {
    if (!text || std::strlen(text) != 72) return false;
    for (size_t index = 0; index < colors.size(); ++index) {
        for (size_t channel = 0; channel < colors[index].size(); ++channel) {
            if (!HexByte(text + (index * 3 + channel) * 2, colors[index][channel])) return false;
        }
    }
    return true;
}

bool IsSupportedLayer(
    int layer,
    const std::array<std::array<unsigned char, 64>, kSlotCount + 1>& slots) {
    for (const auto& alias : kAliases) {
        if (!ValidateCurrentReport(slots[alias.slot], layer, alias.slot)) return false;
    }
    return true;
}

enum class WriteCommitResult {
    Success,
    SlotWriteFailed,
    CommitFailed
};

WriteCommitResult WriteSlotAndCommit(
    hid_device* device,
    hid_write_fn hidWrite,
    const std::array<unsigned char, 64>& readFormat,
    DWORD settleDelayMs = 30) {
    std::array<unsigned char, 65> writeReport{};
    std::memcpy(writeReport.data(), readFormat.data(), readFormat.size());
    writeReport[1] = 0xfd;
    if (hidWrite(device, writeReport.data(), writeReport.size()) != static_cast<int>(writeReport.size())) {
        return WriteCommitResult::SlotWriteFailed;
    }
    if (settleDelayMs > 0) {
        Sleep(settleDelayMs);
    }

    std::array<unsigned char, 65> commit{};
    commit[0] = 0x03;
    commit[1] = 0xfd;
    commit[2] = 0xfe;
    commit[3] = 0xff;
    if (hidWrite(device, commit.data(), commit.size()) != static_cast<int>(commit.size())) {
        return WriteCommitResult::CommitFailed;
    }
    if (settleDelayMs > 0) {
        Sleep(settleDelayMs);
    }
    return WriteCommitResult::Success;
}

bool RestoreSlotAndVerify(
    hid_device* device,
    hid_write_fn hidWrite,
    hid_read_timeout_fn hidReadTimeout,
    int layer,
    int slot,
    const std::array<unsigned char, 64>& expected,
    DWORD settleDelayMs = 30) {
    // Always rewrite and commit the original value. A failed commit can leave
    // a staged slot value even when a read still reports the old value.
    if (WriteSlotAndCommit(device, hidWrite, expected, settleDelayMs) != WriteCommitResult::Success) {
        return false;
    }
    std::array<std::array<unsigned char, 64>, kSlotCount + 1> restoredSlots{};
    return ReadLayer(device, hidWrite, hidReadTimeout, layer, restoredSlots) &&
        restoredSlots[slot] == expected;
}

enum class ProgramTransactionFailure {
    None,
    SlotWrite,
    Commit,
    Verification
};

struct ProgramTransactionResult {
    ProgramTransactionFailure failure;
    bool restoreAttempted;
    bool restoreVerified;

    bool Succeeded() const {
        return failure == ProgramTransactionFailure::None;
    }
};

ProgramTransactionResult ProgramSlotTransaction(
    hid_device* device,
    hid_write_fn hidWrite,
    hid_read_timeout_fn hidReadTimeout,
    int layer,
    int slot,
    const std::array<unsigned char, 64>& original,
    const std::array<unsigned char, 64>& replacement,
    DWORD settleDelayMs = 30) {
    const auto writeResult = WriteSlotAndCommit(device, hidWrite, replacement, settleDelayMs);
    if (writeResult != WriteCommitResult::Success) {
        const bool restored = RestoreSlotAndVerify(
            device, hidWrite, hidReadTimeout, layer, slot, original, settleDelayMs);
        return {
            writeResult == WriteCommitResult::SlotWriteFailed
                ? ProgramTransactionFailure::SlotWrite
                : ProgramTransactionFailure::Commit,
            true,
            restored
        };
    }

    std::array<std::array<unsigned char, 64>, kSlotCount + 1> verificationSlots{};
    if (!ReadLayer(device, hidWrite, hidReadTimeout, layer, verificationSlots) ||
        verificationSlots[slot] != replacement) {
        const bool restored = RestoreSlotAndVerify(
            device, hidWrite, hidReadTimeout, layer, slot, original, settleDelayMs);
        return {ProgramTransactionFailure::Verification, true, restored};
    }

    return {ProgramTransactionFailure::None, false, true};
}

int gMockWriteCall = 0;
int gMockWriteFailureAt = 0;
int gMockWriteSecondFailureAt = 0;
int gMockReadCall = 0;
int gMockReadFailureAt = 0;
int gMockMutationWrites = 0;
bool gMockHasStagedSlot = false;
std::array<unsigned char, 64> gMockStagedSlot{};
std::array<std::array<unsigned char, 64>, kSlotCount + 1> gMockSlots{};

int __cdecl MockWrite(hid_device*, const unsigned char* data, size_t length) {
    ++gMockWriteCall;
    if (length > 1 && data[1] != 0xfa) ++gMockMutationWrites;
    if (gMockWriteFailureAt == gMockWriteCall || gMockWriteSecondFailureAt == gMockWriteCall) {
        return 0;
    }
    if (length == 65 && data[0] == 0x03 && data[1] == 0xfd &&
        data[2] >= 1 && data[2] <= kSlotCount) {
        std::memcpy(gMockStagedSlot.data(), data, gMockStagedSlot.size());
        gMockStagedSlot[1] = 0xfa;
        gMockHasStagedSlot = true;
    } else if (length == 65 && data[0] == 0x03 && data[1] == 0xfd &&
        data[2] == 0xfe && data[3] == 0xff && gMockHasStagedSlot) {
        gMockSlots[gMockStagedSlot[2]] = gMockStagedSlot;
        gMockHasStagedSlot = false;
    }
    return static_cast<int>(length);
}

int __cdecl MockReadTimeout(hid_device*, unsigned char* data, size_t length, int) {
    ++gMockReadCall;
    if (gMockReadFailureAt == gMockReadCall || length < 64) {
        return 0;
    }
    const int slot = ((gMockReadCall - 1) % kSlotCount) + 1;
    std::memcpy(data, gMockSlots[slot].data(), 64);
    return 64;
}

void ResetTransactionMock(
    int writeFailureAt = 0,
    int readFailureAt = 0,
    int secondWriteFailureAt = 0) {
    gMockWriteCall = 0;
    gMockWriteFailureAt = writeFailureAt;
    gMockWriteSecondFailureAt = secondWriteFailureAt;
    gMockReadCall = 0;
    gMockReadFailureAt = readFailureAt;
    gMockMutationWrites = 0;
    gMockHasStagedSlot = false;
}

bool RunTransactionSelfTest() {
    std::array<unsigned char, 64> original{};
    original[0] = 0x03;
    original[1] = 0xfa;
    original[2] = 1;
    original[3] = 0x01;
    original[18] = 0x3a;
    auto replacement = original;
    replacement[18] = 0x3b;

    const auto resetSlots = [&]() {
        for (int slot = 1; slot <= kSlotCount; ++slot) {
            gMockSlots[slot] = original;
            gMockSlots[slot][2] = static_cast<unsigned char>(slot);
        }
    };

    resetSlots();
    ResetTransactionMock(1);
    auto result = ProgramSlotTransaction(
        nullptr, MockWrite, MockReadTimeout, 1, 1, original, replacement, 0);
    if (result.failure != ProgramTransactionFailure::SlotWrite ||
        !result.restoreAttempted || !result.restoreVerified || gMockSlots[1] != original) return false;

    resetSlots();
    ResetTransactionMock(2);
    result = ProgramSlotTransaction(
        nullptr, MockWrite, MockReadTimeout, 1, 1, original, replacement, 0);
    if (result.failure != ProgramTransactionFailure::Commit ||
        !result.restoreAttempted || !result.restoreVerified || gMockSlots[1] != original) return false;

    resetSlots();
    ResetTransactionMock(0, 1);
    result = ProgramSlotTransaction(
        nullptr, MockWrite, MockReadTimeout, 1, 1, original, replacement, 0);
    if (result.failure != ProgramTransactionFailure::Verification ||
        !result.restoreAttempted || !result.restoreVerified || gMockSlots[1] != original) return false;

    resetSlots();
    ResetTransactionMock();
    result = ProgramSlotTransaction(
        nullptr, MockWrite, MockReadTimeout, 1, 1, original, replacement, 0);
    if (!result.Succeeded() || result.restoreAttempted || gMockSlots[1] != replacement) return false;

    // A failed restoration must never be reported as safe.
    resetSlots();
    ResetTransactionMock(2, 0, 4);
    result = ProgramSlotTransaction(
        nullptr, MockWrite, MockReadTimeout, 1, 1, original, replacement, 0);
    if (result.failure != ProgramTransactionFailure::Commit ||
        !result.restoreAttempted || result.restoreVerified) return false;

    auto factoryMode = BuildAliasReport(kAliases[0]);
    factoryMode[5] = 0x01;
    auto appMode = factoryMode;
    appMode[5] = 0x00;
    for (int slot = 1; slot <= kSlotCount; ++slot) {
        gMockSlots[slot] = appMode;
        gMockSlots[slot][2] = static_cast<unsigned char>(slot);
    }
    ResetTransactionMock();
    result = ProgramSlotTransaction(
        nullptr, MockWrite, MockReadTimeout, 1, 1, appMode, factoryMode, 0);
    if (!ValidateCurrentReport(factoryMode, 1, 1) ||
        ValidateReplacementReport(factoryMode, 1, 1) ||
        !result.Succeeded() || gMockSlots[1] != factoryMode) return false;

    return true;
}

bool RunDeviceSafetySelfTest() {
    hid_device_info first{};
    first.path = const_cast<char*>("first");
    first.vendor_id = kVendorId;
    first.product_id = kProductId;
    first.serial_number = const_cast<wchar_t*>(L"DIFFERENT_SERIAL");
    first.usage_page = kUsagePage;
    first.interface_number = kInterfaceNumber;
    if (const auto selected = SelectTarget(&first);
        selected.count != 1 || selected.path != "first" || selected.serial != L"DIFFERENT_SERIAL") return false;
    first.serial_number = nullptr;
    if (const auto selected = SelectTarget(&first); selected.count != 1 || !selected.serial.empty()) return false;
    first.serial_number = const_cast<wchar_t*>(L"DIFFERENT_SERIAL");

    hid_device_info wrong = first;
    wrong.vendor_id = 0xffff;
    if (SelectTarget(&wrong).count != 0) return false;
    wrong = first;
    wrong.product_id = 0xffff;
    if (SelectTarget(&wrong).count != 0) return false;
    wrong = first;
    wrong.interface_number = 1;
    if (SelectTarget(&wrong).count != 0) return false;
    wrong = first;
    wrong.usage_page = 0x0001;
    if (SelectTarget(&wrong).count != 0) return false;

    hid_device_info second = first;
    second.path = const_cast<char*>("second");
    first.next = &second;
    if (SelectTarget(&first).count != 2) return false;
    first.next = nullptr;

    for (int slot = 1; slot <= kSlotCount; ++slot) {
        gMockSlots[slot] = {};
        gMockSlots[slot][0] = 0x03;
        gMockSlots[slot][1] = 0xfa;
        gMockSlots[slot][2] = static_cast<unsigned char>(slot);
        gMockSlots[slot][3] = 0x01;
    }
    for (const auto& alias : kAliases) {
        gMockSlots[alias.slot] = BuildAliasReport(alias);
    }
    std::array<std::array<unsigned char, 64>, kSlotCount + 1> slots{};
    ResetTransactionMock();
    if (!ReadLayer(nullptr, MockWrite, MockReadTimeout, 1, slots) ||
        !IsSupportedLayer(1, slots) || gMockMutationWrites != 0) return false;

    for (const auto& alias : kAliases) gMockSlots[alias.slot][5] = 0x01;
    ResetTransactionMock();
    if (!ReadLayer(nullptr, MockWrite, MockReadTimeout, 1, slots) ||
        !IsSupportedLayer(1, slots) || gMockMutationWrites != 0) return false;
    if (ValidateReplacementReport(gMockSlots[1], 1, 1) ||
        !ValidateCurrentReport(gMockSlots[1], 1, 1)) return false;
    for (const auto& alias : kAliases) gMockSlots[alias.slot][5] = 0x00;

    ResetTransactionMock(0, 1);
    if (ReadLayer(nullptr, MockWrite, MockReadTimeout, 1, slots) || gMockMutationWrites != 0) return false;

    gMockSlots[1][3] = 2;
    ResetTransactionMock();
    if (ReadLayer(nullptr, MockWrite, MockReadTimeout, 1, slots) || gMockMutationWrites != 0) return false;
    gMockSlots[1] = BuildAliasReport(kAliases[0]);

    gMockSlots[1][9] = 0xff;
    ResetTransactionMock();
    if (!ReadLayer(nullptr, MockWrite, MockReadTimeout, 1, slots) ||
        IsSupportedLayer(1, slots) || gMockMutationWrites != 0) return false;
    return true;
}

int gLedMockMutationCall = 0;
int gLedMockWriteFailureAt = 0;
int gLedMockSecondWriteFailureAt = 0;
int gLedMockReadCall = 0;
int gLedMockReadFailureAt = 0;
std::array<unsigned char, 64> gLedMockState{};

int __cdecl MockLedWrite(hid_device*, const unsigned char* data, size_t length) {
    if (length != 65) return 0;
    if (data[1] == 0xfa) return static_cast<int>(length);
    ++gLedMockMutationCall;
    if (gLedMockMutationCall == gLedMockWriteFailureAt ||
        gLedMockMutationCall == gLedMockSecondWriteFailureAt) return 0;
    if (data[1] == 0xfe && data[2] == 0xb0 && data[3] == 0x00) {
        gLedMockState[0] = 0x03;
        gLedMockState[1] = 0xfa;
        gLedMockState[2] = data[4];
        std::memcpy(gLedMockState.data() + 3, data + 5, 36);
    }
    return static_cast<int>(length);
}

int __cdecl MockLedRead(hid_device*, unsigned char* data, size_t length, int) {
    ++gLedMockReadCall;
    if (length < gLedMockState.size() || gLedMockReadCall == gLedMockReadFailureAt) return 0;
    std::memcpy(data, gLedMockState.data(), gLedMockState.size());
    return static_cast<int>(gLedMockState.size());
}

void ResetLedMock(
    const std::array<unsigned char, 64>& original,
    int writeFailureAt = 0,
    int readFailureAt = 0,
    int secondWriteFailureAt = 0) {
    gLedMockState = original;
    gLedMockMutationCall = 0;
    gLedMockWriteFailureAt = writeFailureAt;
    gLedMockSecondWriteFailureAt = secondWriteFailureAt;
    gLedMockReadCall = 0;
    gLedMockReadFailureAt = readFailureAt;
}

bool RunLedTransactionSelfTest() {
    std::array<unsigned char, 64> original{};
    original[0] = 0x03;
    original[1] = 0xfa;
    original[2] = 0x01;
    std::array<std::array<unsigned char, 3>, 12> originalColors{};
    originalColors.fill({0x00, 0x00, 0xff});
    for (size_t index = 0; index < originalColors.size(); ++index) {
        std::memcpy(original.data() + 3 + index * 3, originalColors[index].data(), 3);
    }
    auto targetColors = originalColors;
    targetColors.fill({0xff, 0x00, 0x00});

    ResetLedMock(original);
    auto result = ApplyLedTransaction(
        nullptr, MockLedWrite, MockLedRead, original, 1, targetColors, 0);
    if (!result.succeeded || result.reportsWritten != 3 || result.restoreAttempted ||
        !LedStateMatches(gLedMockState, targetColors)) return false;

    ResetLedMock(original, 2);
    result = ApplyLedTransaction(nullptr, MockLedWrite, MockLedRead, original, 1, targetColors, 0);
    if (result.succeeded || !result.restoreAttempted || !result.restoreVerified ||
        !LedStateMatches(gLedMockState, originalColors)) return false;

    ResetLedMock(original, 0, 1);
    result = ApplyLedTransaction(nullptr, MockLedWrite, MockLedRead, original, 1, targetColors, 0);
    if (result.succeeded || !result.restoreAttempted || !result.restoreVerified ||
        !LedStateMatches(gLedMockState, originalColors)) return false;

    ResetLedMock(original, 2, 0, 3);
    result = ApplyLedTransaction(nullptr, MockLedWrite, MockLedRead, original, 1, targetColors, 0);
    if (result.succeeded || !result.restoreAttempted || result.restoreVerified) return false;

    ResetLedMock(original);
    result = ApplyLedTransaction(nullptr, MockLedWrite, MockLedRead, original, 1, originalColors, 0);
    return result.succeeded && result.reportsWritten == 0 && gLedMockMutationCall == 0;
}

}  // namespace

int main(int argc, char** argv) {
    const bool discover = argc == 2 && std::strcmp(argv[1], "discover") == 0;
    const bool readLayer1 = argc == 2 && std::strcmp(argv[1], "read-layer1") == 0;
    const bool readLayer = argc == 3 && std::strcmp(argv[1], "read-layer") == 0;
    const bool readLed = argc == 2 && std::strcmp(argv[1], "read-led") == 0;
    const bool setLed = argc == 3 && std::strcmp(argv[1], "set-led") == 0;
    const bool setLedLayout = argc == 14 && std::strcmp(argv[1], "set-led-layout") == 0;
    const bool restoreLed = argc == 4 && std::strcmp(argv[1], "restore-led") == 0;
    const bool encodeLedLayout = argc == 14 && std::strcmp(argv[1], "encode-led-layout") == 0;
    const bool encodeInput = argc == 3 && std::strcmp(argv[1], "encode-input") == 0;
    const bool programInput = argc == 4 && std::strcmp(argv[1], "program-input") == 0;
    const bool programReportLegacy = argc == 5 && std::strcmp(argv[1], "program-report") == 0;
    const bool programReportLayered = argc == 6 && std::strcmp(argv[1], "program-report") == 0;
    const bool programReport = programReportLegacy || programReportLayered;
    const bool restoreReport = argc == 6 && std::strcmp(argv[1], "restore-report") == 0;
    const bool testRollback = argc == 4 && std::strcmp(argv[1], "test-rollback") == 0;
    const bool selfTestTransaction = argc == 2 && std::strcmp(argv[1], "self-test-transaction") == 0;
    const bool selfTestKeyCatalog = argc == 2 && std::strcmp(argv[1], "self-test-key-catalog") == 0;
    const bool selfTestDeviceSafety = argc == 2 && std::strcmp(argv[1], "self-test-device-safety") == 0;
    const bool selfTestLedTransaction = argc == 2 && std::strcmp(argv[1], "self-test-led-transaction") == 0;
    std::array<unsigned char, 3> ledColor{};
    std::array<std::array<unsigned char, 3>, 12> ledColors{};
    std::array<unsigned char, 64> expectedSlot{};
    std::array<unsigned char, 64> replacementSlot{};
    int targetLayer = 1;
    int targetLedMode = 1;
    if ((readLayer && !TryParseLayer(argv[2], targetLayer)) ||
        ((programReportLayered || restoreReport) && !TryParseLayer(argv[2], targetLayer))) {
        PrintError("invalid_layer", 66);
        return 66;
    }
    const int inputArgument = (programReportLayered || restoreReport) ? 3 : 2;
    const int expectedArgument = (programReportLayered || restoreReport) ? 4 : 3;
    const int replacementArgument = (programReportLayered || restoreReport) ? 5 : 4;
    const AliasDefinition* alias = (encodeInput || programInput || programReport || restoreReport || testRollback)
        ? FindAlias(argv[inputArgument])
        : nullptr;
    if (setLed && !GetStatusColor(argv[2], ledColor)) {
        PrintError("unsupported_color", 65);
        return 65;
    }
    if (setLed) {
        ledColors.fill(ledColor);
    }
    if (setLedLayout || encodeLedLayout) {
        for (size_t index = 0; index < ledColors.size(); ++index) {
            if (!GetStatusColor(argv[index + 2], ledColors[index])) {
                PrintError("unsupported_color", 65);
                return 65;
            }
        }
    }
    if ((encodeInput || programInput || programReport || restoreReport || testRollback) && !alias) {
        PrintError("unsupported_input", 67);
        return 67;
    }
    if ((programInput || programReport || restoreReport || testRollback) &&
        !ParseHexReport(argv[expectedArgument], expectedSlot)) {
        PrintError("invalid_expected_slot", 68);
        return 68;
    }
    if (restoreLed &&
        ((std::strlen(argv[2]) != 1 || argv[2][0] < '0' || argv[2][0] > '5') ||
            !ParseLedColors(argv[3], ledColors))) {
        PrintError("invalid_led_snapshot", 70);
        return 70;
    }
    if (restoreLed) targetLedMode = argv[2][0] - '0';
    if ((programReport || restoreReport) && !MatchesLayerSlotHeader(expectedSlot, targetLayer, alias->slot)) {
        PrintError("invalid_expected_slot", 68);
        return 68;
    }
    if (programReport && (!ParseHexReport(argv[replacementArgument], replacementSlot) ||
            (replacementSlot != expectedSlot &&
                !ValidateReplacementReport(replacementSlot, targetLayer, alias->slot)))) {
        PrintError("invalid_replacement_slot", 69);
        return 69;
    }
    if (restoreReport && (!ParseHexReport(argv[replacementArgument], replacementSlot) ||
            !ValidateCurrentReport(replacementSlot, targetLayer, alias->slot))) {
        PrintError("invalid_restore_slot", 71);
        return 71;
    }
    if (encodeInput) {
        const auto encoded = BuildAliasReport(*alias);
        std::printf("{\"ok\":true,\"input\":\"%s\",\"slot\":%d,\"hex\":\"", alias->inputId, alias->slot);
        PrintHex(encoded.data(), encoded.size());
        std::printf("\"}\n");
        return 0;
    }
    if (encodeLedLayout) {
        std::array<unsigned char, 65> report{};
        if (!BuildLedReport(0, ledColors, report)) {
            PrintError("invalid_led_template", 8);
            return 8;
        }
        std::printf("{\"ok\":true,\"layout\":true,\"report0Hex\":\"");
        PrintHex(report.data(), report.size());
        std::printf("\"}\n");
        return 0;
    }
    if (selfTestTransaction) {
        const bool passed = RunTransactionSelfTest();
        std::printf("{\"ok\":%s,\"endToEnd\":true,\"slotWriteFailure\":true,\"commitFailure\":true,\"readFailure\":true,\"forcedRestore\":true,\"restoreFailureDetected\":true}\n", passed ? "true" : "false");
        return passed ? 0 : 15;
    }
    if (selfTestKeyCatalog) {
        const bool passed = RunKeyCatalogSelfTest();
        std::printf(
            "{\"ok\":%s,\"standardKeyboardKeys\":%s,\"consumerKeysRejected\":%s,\"layersValidated\":3}\n",
            passed ? "true" : "false",
            passed ? "true" : "false",
            passed ? "true" : "false");
        return passed ? 0 : 16;
    }
    if (selfTestDeviceSafety) {
        const bool passed = RunDeviceSafetySelfTest();
        std::printf(
            "{\"ok\":%s,\"differentSerial\":true,\"identityFilter\":true,"
            "\"multipleRejected\":true,\"invalidReportsRejected\":true,\"mutationWrites\":0}\n",
            passed ? "true" : "false");
        return passed ? 0 : 18;
    }
    if (selfTestLedTransaction) {
        const bool passed = RunLedTransactionSelfTest();
        std::printf(
            "{\"ok\":%s,\"writeFailureRestored\":%s,\"verifyFailureRestored\":%s,"
            "\"restoreFailureDetected\":%s,\"noOpWrites\":0}\n",
            passed ? "true" : "false", passed ? "true" : "false",
            passed ? "true" : "false", passed ? "true" : "false");
        return passed ? 0 : 20;
    }
    if (!discover && !readLayer1 && !readLayer && !readLed && !setLed && !setLedLayout && !restoreLed &&
        !programInput && !programReport && !restoreReport && !testRollback) {
        PrintError("unsupported_command", 64);
        return 64;
    }

    const std::string dllPath = SiblingDllPath();
    HMODULE module = dllPath.empty() ? nullptr : LoadLibraryA(dllPath.c_str());
    if (!module) {
        PrintError("hidapi_load_failed", 2);
        return 2;
    }

    const auto hidInit = Load<hid_init_fn>(module, "hid_init");
    const auto hidExit = Load<hid_exit_fn>(module, "hid_exit");
    const auto hidEnumerate = Load<hid_enumerate_fn>(module, "hid_enumerate");
    const auto hidFreeEnumeration = Load<hid_free_enumeration_fn>(module, "hid_free_enumeration");
    const auto hidOpenPath = Load<hid_open_path_fn>(module, "hid_open_path");
    const auto hidWrite = Load<hid_write_fn>(module, "hid_write");
    const auto hidReadTimeout = Load<hid_read_timeout_fn>(module, "hid_read_timeout");
    const auto hidClose = Load<hid_close_fn>(module, "hid_close");
    if (!hidInit || !hidExit || !hidEnumerate || !hidFreeEnumeration ||
        !hidOpenPath || !hidWrite || !hidReadTimeout || !hidClose) {
        PrintError("hidapi_exports_missing", 3);
        FreeLibrary(module);
        return 3;
    }
    if (hidInit() != 0) {
        PrintError("hidapi_init_failed", 4);
        FreeLibrary(module);
        return 4;
    }

    hid_device_info* devices = hidEnumerate(kVendorId, kProductId);
    const auto target = SelectTarget(devices);

    if (target.count == 0) {
        std::printf("{\"ok\":true,\"connected\":false,\"device\":\"12-key-2-knob\"}\n");
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 0;
    }
    if (target.count > 1) {
        PrintError("multiple_matching_devices", 18);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 18;
    }

    hid_device* device = hidOpenPath(target.path.c_str());
    if (!device) {
        PrintError("device_open_failed", 5);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 5;
    }

    if (discover) {
        std::array<std::array<unsigned char, 64>, kSlotCount + 1> compatibilitySlots{};
        if (!ReadLayer(device, hidWrite, hidReadTimeout, 1, compatibilitySlots) ||
            !IsSupportedLayer(1, compatibilitySlots)) {
            PrintError("incompatible_device", 19);
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 19;
        }
        std::printf(
            "{\"ok\":true,\"connected\":true,\"device\":\"12-key-2-knob\","
            "\"transport\":\"USB\",\"interface\":0,\"usagePage\":\"FF00\",\"serial\":");
        PrintJsonString(target.serial);
        std::printf("}\n");
        hidClose(device);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 0;
    }

    if (readLed) {
        std::array<unsigned char, 64> currentRgb{};
        if (!ReadLedState(device, hidWrite, hidReadTimeout, currentRgb)) {
            PrintError("led_read_failed", 16);
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 16;
        }
        std::printf("{\"ok\":true,\"connected\":true,\"mode\":%u,\"colorsHex\":\"", currentRgb[2]);
        PrintHex(currentRgb.data() + 3, 36);
        std::printf("\"}\n");
        hidClose(device);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 0;
    }

    if (setLed || setLedLayout || restoreLed) {
        std::array<std::array<unsigned char, 64>, kSlotCount + 1> compatibilitySlots{};
        if (!ReadLayer(device, hidWrite, hidReadTimeout, 1, compatibilitySlots) ||
            !IsSupportedLayer(1, compatibilitySlots)) {
            PrintError("incompatible_device", 19);
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 19;
        }
        // The firmware ignores RGB writes after reconnect until its current
        // RGB record has been read once. This mirrors MINI_KEYBOARD's save flow.
        std::array<unsigned char, 64> currentRgb{};
        if (!ReadLedState(device, hidWrite, hidReadTimeout, currentRgb)) {
            PrintError("led_prepare_failed", 16);
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 16;
        }
        const unsigned char ledMode = static_cast<unsigned char>(restoreLed ? targetLedMode : 1);
        if (LedStateMatches(currentRgb, ledColors, ledMode)) {
            if (setLed) {
                std::printf("{\"ok\":true,\"connected\":true,\"prepared\":true,\"verified\":true,\"mode\":1,\"color\":\"%s\",\"reportsWritten\":0}\n", argv[2]);
            } else if (setLedLayout) {
                std::printf("{\"ok\":true,\"connected\":true,\"prepared\":true,\"verified\":true,\"mode\":1,\"layout\":true,\"reportsWritten\":0}\n");
            } else {
                std::printf("{\"ok\":true,\"connected\":true,\"prepared\":true,\"verified\":true,\"mode\":%u,\"restored\":true,\"reportsWritten\":0}\n", ledMode);
            }
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 0;
        }
        const auto transaction = ApplyLedTransaction(
            device, hidWrite, hidReadTimeout, currentRgb, ledMode, ledColors);
        if (!transaction.succeeded) {
            std::printf(
                "{\"ok\":false,\"connected\":true,\"error\":\"led_transaction_failed\","
                "\"code\":17,\"reportsWritten\":%d,\"restoreAttempted\":%s,\"restoreVerified\":%s}\n",
                transaction.reportsWritten,
                transaction.restoreAttempted ? "true" : "false",
                transaction.restoreVerified ? "true" : "false");
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 17;
        }
        if (setLed) {
            std::printf("{\"ok\":true,\"connected\":true,\"prepared\":true,\"verified\":true,\"mode\":1,\"color\":\"%s\",\"reportsWritten\":%d}\n", argv[2], transaction.reportsWritten);
        } else if (setLedLayout) {
            std::printf("{\"ok\":true,\"connected\":true,\"prepared\":true,\"verified\":true,\"mode\":1,\"layout\":true,\"reportsWritten\":%d}\n", transaction.reportsWritten);
        } else {
            std::printf("{\"ok\":true,\"connected\":true,\"prepared\":true,\"verified\":true,\"mode\":%u,\"restored\":true,\"reportsWritten\":%d}\n", ledMode, transaction.reportsWritten);
        }
        hidClose(device);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 0;
    }

    std::array<std::array<unsigned char, 64>, kSlotCount + 1> slots{};
    if (!ReadLayer(device, hidWrite, hidReadTimeout, targetLayer, slots)) {
        PrintError("invalid_keymap_response", 7);
        hidClose(device);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 7;
    }
    if ((programInput || programReport || restoreReport || testRollback) &&
        !IsSupportedLayer(targetLayer, slots)) {
        PrintError("incompatible_device", 19);
        hidClose(device);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 19;
    }

    if (programInput || programReport || restoreReport) {
        const auto replacement = (programReport || restoreReport) ? replacementSlot : BuildAliasReport(*alias);
        const auto& currentSlot = slots[alias->slot];
        if (currentSlot != expectedSlot) {
            PrintError("slot_changed_since_read", 10);
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 10;
        }
        if (currentSlot == replacement) {
            std::printf("{\"ok\":true,\"connected\":true,\"layer\":%d,\"input\":\"%s\",\"slot\":%d,\"changed\":false,\"verified\":true,\"reportsWritten\":0,\"hex\":\"", targetLayer, alias->inputId, alias->slot);
            PrintHex(replacement.data(), replacement.size());
            std::printf("\"}\n");
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 0;
        }

        const auto transaction = ProgramSlotTransaction(
            device, hidWrite, hidReadTimeout, targetLayer, alias->slot, currentSlot, replacement);
        if (!transaction.Succeeded()) {
            const char* error = nullptr;
            int exitCode = 12;
            if (transaction.failure == ProgramTransactionFailure::SlotWrite) {
                error = transaction.restoreVerified
                    ? "slot_write_failed_restored_and_verified"
                    : "slot_write_failed_restore_failed";
            } else if (transaction.failure == ProgramTransactionFailure::Commit) {
                error = transaction.restoreVerified
                    ? "slot_commit_failed_restored_and_verified"
                    : "slot_commit_failed_restore_failed";
            } else {
                error = transaction.restoreVerified
                    ? "slot_verification_failed_restored_and_verified"
                    : "slot_verification_failed_restore_failed";
                exitCode = 13;
            }
            std::printf(
                "{\"ok\":false,\"connected\":true,\"layer\":%d,\"input\":\"%s\",\"slot\":%d,"
                "\"changed\":false,\"verified\":false,\"restoreAttempted\":%s,\"restoreVerified\":%s,"
                "\"error\":\"%s\",\"code\":%d}\n",
                targetLayer,
                alias->inputId,
                alias->slot,
                transaction.restoreAttempted ? "true" : "false",
                transaction.restoreVerified ? "true" : "false",
                error,
                exitCode);
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return exitCode;
        }

        std::printf("{\"ok\":true,\"connected\":true,\"layer\":%d,\"input\":\"%s\",\"slot\":%d,\"changed\":true,\"verified\":true,\"reportsWritten\":2,\"hex\":\"", targetLayer, alias->inputId, alias->slot);
        PrintHex(replacement.data(), replacement.size());
        std::printf("\"}\n");
        hidClose(device);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 0;
    }

    if (testRollback) {
        const auto& original = slots[alias->slot];
        if (original != expectedSlot) {
            PrintError("slot_changed_since_read", 10);
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 10;
        }

        auto diagnostic = BuildAliasReport(*alias);
        diagnostic[18] = diagnostic[18] == 0x73 ? 0x72 : 0x73;  // Safe F23/F24 diagnostic alias.
        const bool diagnosticWritten =
            WriteSlotAndCommit(device, hidWrite, diagnostic) == WriteCommitResult::Success;
        std::array<std::array<unsigned char, 64>, kSlotCount + 1> diagnosticSlots{};
        const bool diagnosticVerified = diagnosticWritten &&
            ReadLayer(device, hidWrite, hidReadTimeout, targetLayer, diagnosticSlots) &&
            diagnosticSlots[alias->slot] == diagnostic;

        // Use the production transaction path to force the original value back.
        // Passing the original as both values makes every retry converge on the
        // safe value instead of restoring the diagnostic alias.
        const auto restoreTransaction = ProgramSlotTransaction(
            device, hidWrite, hidReadTimeout, targetLayer, alias->slot, original, original);
        const bool restoreVerified =
            restoreTransaction.Succeeded() || restoreTransaction.restoreVerified;
        if (!diagnosticVerified || !restoreVerified) {
            PrintError(restoreVerified ? "rollback_test_diagnostic_failed_original_restored" : "rollback_test_restore_failed", 14);
            hidClose(device);
            hidFreeEnumeration(devices);
            hidExit();
            FreeLibrary(module);
            return 14;
        }

        std::printf("{\"ok\":true,\"connected\":true,\"input\":\"%s\",\"slot\":%d,\"diagnosticVerified\":true,\"rollbackVerified\":true,\"transactionRestore\":true,\"reportsWritten\":4,\"restoredHex\":\"", alias->inputId, alias->slot);
        PrintHex(original.data(), original.size());
        std::printf("\"}\n");
        hidClose(device);
        hidFreeEnumeration(devices);
        hidExit();
        FreeLibrary(module);
        return 0;
    }

    std::printf("{\"ok\":true,\"connected\":true,\"layer\":%d,\"slots\":[", targetLayer);
    for (int slot = 1; slot <= kSlotCount; ++slot) {
        if (slot > 1) {
            std::putchar(',');
        }
        std::printf("{\"slot\":%d,\"hex\":\"", slot);
        PrintHex(slots[slot].data(), slots[slot].size());
        std::printf("\"}");
    }
    std::printf("]}\n");
    hidClose(device);
    hidFreeEnumeration(devices);
    hidExit();
    FreeLibrary(module);
    return 0;
}
