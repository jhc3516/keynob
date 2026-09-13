namespace Keynob.Services;

public enum LedDisplayTarget
{
    BaseLayout,
    StatusColor
}

public sealed record LedDisplayPlan(
    LedDisplayTarget ImmediateTarget,
    bool RestoreBaseAfterDelay);

public static class LedDisplayPolicy
{
    public static LedDisplayPlan Decide(
        string? status,
        int activeSessionCount,
        bool restoreBaseAfterCompletion,
        bool isStartupOrUsbConnection)
    {
        if (status is null)
        {
            return new(LedDisplayTarget.BaseLayout, false);
        }

        if (status == "completed" && activeSessionCount == 0 && restoreBaseAfterCompletion)
        {
            return isStartupOrUsbConnection
                ? new(LedDisplayTarget.BaseLayout, false)
                : new(LedDisplayTarget.StatusColor, true);
        }

        return new(LedDisplayTarget.StatusColor, false);
    }
}
