using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexKeyboardStudio.Services;

public sealed record CodexHookInspection(
    bool Installed,
    bool Valid,
    int HandlerCount,
    string Message);

public sealed record CodexHookOperationResult(bool Ok, string Message);

public sealed class CodexHookInstallationService
{
    private static readonly string[] ExpectedEvents =
    [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse",
        "PostToolUse", "Stop", "SessionEnd"
    ];

    private readonly string _codexHome;
    private readonly string _appDirectory;
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public CodexHookInstallationService(string? codexHome = null, string? appDirectory = null)
    {
        _codexHome = codexHome ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        _appDirectory = appDirectory ?? AppContext.BaseDirectory;
    }

    public CodexHookInspection Inspect()
    {
        var hooksPath = Path.Combine(_codexHome, "hooks.json");
        var installedClient = Path.Combine(_codexHome, "CodexStatusHookClient.exe");
        var packagedClient = Path.Combine(_appDirectory, "CodexStatusHookClient.exe");
        if (!File.Exists(hooksPath) && !File.Exists(installedClient))
        {
            return new(false, false, 0, "설치 필요");
        }

        try
        {
            var bytes = File.ReadAllBytes(hooksPath);
            if (HasUtf8Bom(bytes))
            {
                return new(File.Exists(installedClient), false, 0, "설정 파일 BOM 오류 · 설치/복구 필요");
            }

            using var document = JsonDocument.Parse(bytes);
            if (!document.RootElement.TryGetProperty("hooks", out var hooks) ||
                hooks.ValueKind != JsonValueKind.Object)
            {
                return new(File.Exists(installedClient), false, 0, "훅 설정 구조 오류 · 설치/복구 필요");
            }

            var handlerCount = 0;
            var validEventCount = 0;
            foreach (var eventName in ExpectedEvents)
            {
                if (!hooks.TryGetProperty(eventName, out var groups) || groups.ValueKind != JsonValueKind.Array)
                {
                    continue;
                }
                var eventHandlerCount = 0;
                foreach (var group in groups.EnumerateArray())
                {
                    if (!group.TryGetProperty("hooks", out var handlers) || handlers.ValueKind != JsonValueKind.Array)
                    {
                        continue;
                    }
                    eventHandlerCount += handlers.EnumerateArray().Count(handler =>
                        handler.TryGetProperty("command", out var command) &&
                        command.ValueKind == JsonValueKind.String &&
                        handler.TryGetProperty("type", out var type) &&
                        type.ValueKind == JsonValueKind.String &&
                        type.GetString() == "command" &&
                        string.Equals(command.GetString(), installedClient, StringComparison.OrdinalIgnoreCase));
                }
                handlerCount += eventHandlerCount;
                if (eventHandlerCount == 1)
                {
                    validEventCount++;
                }
            }

            var binariesMatch = File.Exists(installedClient) && File.Exists(packagedClient) &&
                SHA256.HashData(File.ReadAllBytes(installedClient))
                    .SequenceEqual(SHA256.HashData(File.ReadAllBytes(packagedClient)));
            var valid = handlerCount == ExpectedEvents.Length &&
                validEventCount == ExpectedEvents.Length && binariesMatch;
            var installed = handlerCount > 0 || File.Exists(installedClient);
            return valid
                ? new(true, true, handlerCount, "설치 정상 · Codex /hooks 신뢰 확인 필요")
                : new(installed, false, handlerCount, installed ? "설치 불완전 · 설치/복구 필요" : "설치 필요");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new(File.Exists(installedClient), false, 0, $"검사 실패 · {exception.Message}");
        }
    }

    public Task<CodexHookOperationResult> ApplyAsync(bool uninstall, CancellationToken cancellationToken = default)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            Directory.CreateDirectory(_codexHome);
            var hooksPath = Path.Combine(_codexHome, "hooks.json");
            var installedClient = Path.Combine(_codexHome, "CodexStatusHookClient.exe");
            var packagedClient = Path.Combine(_appDirectory, "CodexStatusHookClient.exe");
            var config = File.Exists(hooksPath)
                ? JsonNode.Parse(StrictUtf8.GetString(File.ReadAllBytes(hooksPath))) as JsonObject
                    ?? throw new JsonException("Codex hooks.json의 최상위 값이 객체가 아닙니다")
                : new JsonObject
                {
                    ["description"] = "Codex user hooks",
                    ["hooks"] = new JsonObject()
                };
            if (!config.TryGetPropertyValue("hooks", out var hooksNode) || hooksNode is null)
            {
                config["hooks"] = hooksNode = new JsonObject();
            }
            if (hooksNode is not JsonObject hooks)
            {
                throw new JsonException("Codex hooks.json의 hooks 값이 객체가 아닙니다");
            }

            foreach (var eventName in ExpectedEvents)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var preservedGroups = new JsonArray();
                if (hooks.TryGetPropertyValue(eventName, out var groupsNode) && groupsNode is not null)
                {
                    if (groupsNode is not JsonArray groups)
                    {
                        throw new JsonException($"Codex hooks.json의 {eventName} 값이 배열이 아닙니다");
                    }
                    foreach (var groupNode in groups)
                    {
                        if (groupNode is not JsonObject group ||
                            !group.TryGetPropertyValue("hooks", out var handlersNode) ||
                            handlersNode is not JsonArray handlers)
                        {
                            throw new JsonException($"Codex hooks.json의 {eventName} 훅 구조가 올바르지 않습니다");
                        }

                        var preservedHandlers = new JsonArray(
                            handlers.Where(handler => !IsMacroPadHandler(handler, installedClient))
                                .Select(handler => handler?.DeepClone()).ToArray());
                        if (preservedHandlers.Count > 0)
                        {
                            var preservedGroup = group.DeepClone().AsObject();
                            preservedGroup["hooks"] = preservedHandlers;
                            preservedGroups.Add(preservedGroup);
                        }
                    }
                }

                if (!uninstall)
                {
                    preservedGroups.Add(new JsonObject
                    {
                        ["hooks"] = new JsonArray(new JsonObject
                        {
                            ["type"] = "command",
                            ["command"] = installedClient,
                            ["timeout"] = 1
                        })
                    });
                }

                if (preservedGroups.Count > 0)
                {
                    hooks[eventName] = preservedGroups;
                }
                else
                {
                    hooks.Remove(eventName);
                }
            }

            if (!uninstall)
            {
                if (!File.Exists(packagedClient))
                {
                    throw new FileNotFoundException("배포 폴더에 Codex 훅 클라이언트가 없습니다", packagedClient);
                }
                ReplaceFile(packagedClient, installedClient);
            }

            WriteJsonAtomically(hooksPath, config);
            if (uninstall && File.Exists(installedClient))
            {
                File.Delete(installedClient);
            }

            var inspection = Inspect();
            var succeeded = uninstall ? !inspection.Installed : inspection.Valid;
            return Task.FromResult<CodexHookOperationResult>(succeeded
                ? new(true, uninstall ? "이 앱의 Codex 훅 7개를 제거했습니다" : inspection.Message)
                : new(false, inspection.Message));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
            InvalidOperationException or JsonException or DecoderFallbackException)
        {
            return Task.FromResult(new CodexHookOperationResult(false, $"훅 작업 실패 · {exception.Message}"));
        }
    }

    private static bool IsMacroPadHandler(JsonNode? handler, string installedClient) =>
        handler is JsonObject handlerObject &&
        handlerObject["command"] is JsonValue commandValue &&
        commandValue.TryGetValue<string>(out var command) &&
        string.Equals(command, installedClient, StringComparison.OrdinalIgnoreCase);

    private static void ReplaceFile(string source, string destination)
    {
        var temporaryPath = $"{destination}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.Copy(source, temporaryPath);
            if (File.Exists(destination))
            {
                File.Replace(temporaryPath, destination, null);
            }
            else
            {
                File.Move(temporaryPath, destination);
            }
        }
        finally
        {
            File.Delete(temporaryPath);
        }
    }

    private static void WriteJsonAtomically(string path, JsonObject config)
    {
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporaryPath, config.ToJsonString(JsonOptions), new System.Text.UTF8Encoding(false));
            if (File.Exists(path))
            {
                File.Replace(temporaryPath, path, null);
            }
            else
            {
                File.Move(temporaryPath, path);
            }
        }
        finally
        {
            File.Delete(temporaryPath);
        }
    }

    public static bool HasUtf8Bom(ReadOnlySpan<byte> bytes) =>
        bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
}
