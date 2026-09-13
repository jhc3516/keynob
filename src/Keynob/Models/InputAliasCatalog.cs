namespace Keynob.Models;

public sealed record InputAlias(int Layer, string InputId, int Slot, uint VirtualKey);

public static class InputAliasCatalog
{
    public const uint F1 = 0x70;
    public const uint Left = 0x25;
    public const uint Up = 0x26;
    public const uint Right = 0x27;
    public const uint Down = 0x28;
    public const uint Enter = 0x0D;
    public const uint M = 0x4D;

    public static readonly IReadOnlyList<InputAlias> All =
    [
        new(1, "key01", 1, F1), new(1, "key02", 2, F1 + 1), new(1, "key03", 3, F1 + 2),
        new(1, "key04", 4, F1 + 3), new(1, "key05", 5, F1 + 4), new(1, "key06", 6, F1 + 5),
        new(1, "key07", 7, F1 + 6), new(1, "key08", 8, F1 + 7), new(1, "key09", 9, F1 + 8),
        new(1, "key10", 10, F1 + 9), new(1, "key11", 11, F1 + 10), new(1, "key12", 12, F1 + 11),
        new(1, "knob1_ccw", 16, Left), new(1, "knob1_press", 17, Enter), new(1, "knob1_cw", 18, Right),
        new(1, "knob2_ccw", 19, Up), new(1, "knob2_press", 20, M), new(1, "knob2_cw", 21, Down),

        new(2, "key01", 1, 0x7C), new(2, "key02", 2, 0x7D), new(2, "key03", 3, 0x7E),
        new(2, "key04", 4, 0x7F), new(2, "key05", 5, 0x80), new(2, "key06", 6, 0x81),
        new(2, "key07", 7, 0x82), new(2, "key08", 8, 0x83), new(2, "key09", 9, 0x84),
        new(2, "key10", 10, 0x85), new(2, "key11", 11, 0x86), new(2, "key12", 12, 0x87),
        new(2, "knob1_ccw", 16, 0x24), new(2, "knob1_press", 17, 0x23), new(2, "knob1_cw", 18, 0x21),
        new(2, "knob2_ccw", 19, 0x22), new(2, "knob2_press", 20, 0x2D), new(2, "knob2_cw", 21, 0x2E),

        new(3, "key01", 1, 0x41), new(3, "key02", 2, 0x42), new(3, "key03", 3, 0x44),
        new(3, "key04", 4, 0x45), new(3, "key05", 5, 0x46), new(3, "key06", 6, 0x47),
        new(3, "key07", 7, 0x48), new(3, "key08", 8, 0x49), new(3, "key09", 9, 0x4A),
        new(3, "key10", 10, 0x4B), new(3, "key11", 11, 0x4C), new(3, "key12", 12, 0x4E),
        new(3, "knob1_ccw", 16, 0x4F), new(3, "knob1_press", 17, 0x50), new(3, "knob1_cw", 18, 0x51),
        new(3, "knob2_ccw", 19, 0x52), new(3, "knob2_press", 20, 0x53), new(3, "knob2_cw", 21, 0x54)
    ];

    public static bool TryGetByVirtualKey(uint virtualKey, out InputAlias alias)
    {
        alias = All.FirstOrDefault(candidate => candidate.VirtualKey == virtualKey)!;
        return alias is not null;
    }

    public static bool TryGetByInputId(string inputId, out InputAlias alias)
        => TryGetByInputId(1, inputId, out alias);

    public static bool TryGetByInputId(int layer, string inputId, out InputAlias alias)
    {
        alias = All.FirstOrDefault(candidate =>
            candidate.Layer == layer && candidate.InputId == inputId)!;
        return alias is not null;
    }
}
