using System;

namespace SecondDisplay.Host;

/// <summary>
/// Status check indicating whether the tablet is unlocked, awake, and in "data transfer" (MTP/PTP) USB mode.
/// </summary>
public readonly record struct DeviceReadiness(bool IsReady, string Reason)
{
    public static DeviceReadiness Parse(string? output)
    {
        if (string.IsNullOrWhiteSpace(output))
            return new DeviceReadiness(false, "No response from device");

        string trimmed = output.Trim();
        if (trimmed == "READY")
            return new DeviceReadiness(true, "Ready (unlocked, MTP active)");

        if (trimmed.StartsWith("USB_NOT_MTP", StringComparison.OrdinalIgnoreCase))
        {
            int colon = trimmed.IndexOf(':');
            string state = colon >= 0 ? trimmed[(colon + 1)..].Trim() : "";
            string reason = string.IsNullOrEmpty(state)
                ? "USB mode is not data transfer"
                : $"USB mode is not data transfer ({state})";
            return new DeviceReadiness(false, reason);
        }

        if (trimmed == "LOCKED")
            return new DeviceReadiness(false, "Device is locked");

        if (trimmed == "SCREEN_OFF")
            return new DeviceReadiness(false, "Screen is off / asleep");

        return new DeviceReadiness(false, $"Device not ready ({trimmed})");
    }
}
