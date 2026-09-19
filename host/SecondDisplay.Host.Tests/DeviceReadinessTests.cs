using Xunit;

namespace SecondDisplay.Host.Tests;

public class DeviceReadinessTests
{
    [Fact]
    public void Parse_Ready_ReturnsIsReadyTrue()
    {
        var result = DeviceReadiness.Parse("READY\n");
        Assert.True(result.IsReady);
        Assert.Contains("Ready", result.Reason);
    }

    [Theory]
    [InlineData("USB_NOT_MTP:adb", "USB mode is not data transfer (adb)")]
    [InlineData("USB_NOT_MTP:none", "USB mode is not data transfer (none)")]
    [InlineData("USB_NOT_MTP", "USB mode is not data transfer")]
    public void Parse_UsbNotMtp_ReturnsFalseWithReason(string output, string expectedSubstr)
    {
        var result = DeviceReadiness.Parse(output);
        Assert.False(result.IsReady);
        Assert.Contains(expectedSubstr, result.Reason);
    }

    [Fact]
    public void Parse_Locked_ReturnsFalse()
    {
        var result = DeviceReadiness.Parse("LOCKED\r\n");
        Assert.False(result.IsReady);
        Assert.Equal("Device is locked", result.Reason);
    }

    [Fact]
    public void Parse_ScreenOff_ReturnsFalse()
    {
        var result = DeviceReadiness.Parse("SCREEN_OFF");
        Assert.False(result.IsReady);
        Assert.Equal("Screen is off / asleep", result.Reason);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    public void Parse_EmptyOrNull_ReturnsFalse(string? output)
    {
        var result = DeviceReadiness.Parse(output!);
        Assert.False(result.IsReady);
    }
}
