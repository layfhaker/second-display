namespace SecondDisplay.Host;

/// <summary>
/// Fps/capture flags parsed from argv. Extracted verbatim from Program.cs so the
/// same defaults/semantics are shared between the manual CLI path and a future orchestrator.
/// </summary>
public sealed class FpsOptions
{
    public bool Adaptive;        // true when --fps absent or "auto"
    public int MaxAdaptiveFps;   // --max-fps, default 30 (Iris Xe + VDD cannot sustain 60 encode)
    public int TargetFps;        // when not adaptive, default 30
    public bool ForceGdi;        // --gdi
    public bool ForceCpu;        // --cpu
    public bool ForceGpu;        // --gpu
    public int RequestedEncW;    // --encode-width, 0 = same as capture
    public int RequestedEncH;    // --encode-height, 0 = derive from width & capture aspect
    public bool VerboseInput;    // --verbose-input: log every key/touch event (off by default; hot path)

    public static FpsOptions FromArgs(string[] args)
    {
        string? fpsArg = GetArg(args, "--fps");
        bool adaptive = string.IsNullOrWhiteSpace(fpsArg) || fpsArg.Equals("auto", StringComparison.OrdinalIgnoreCase);
        // Cap adaptive at 30 by default: zero-copy HEVC on this machine tops out ~15–20 fps at
        // 1280-wide; chasing 60 burns the iGPU and makes the whole laptop lag.
        int maxAdaptiveFps = int.TryParse(GetArg(args, "--max-fps") ?? "30", out var _maxFps) && _maxFps > 0 ? _maxFps : 30;
        int targetFps = !adaptive && int.TryParse(fpsArg, out var _fps) && _fps > 0 ? _fps : 30;

        bool forceGdi = args.Contains("--gdi");
        bool forceCpu = args.Contains("--cpu");
        bool forceGpu = args.Contains("--gpu");

        int requestedEncW = int.TryParse(GetArg(args, "--encode-width"), out var _encW) && _encW > 0 ? _encW : 0;
        int requestedEncH = int.TryParse(GetArg(args, "--encode-height"), out var _encH) && _encH > 0 ? _encH : 0;
        bool verboseInput = args.Contains("--verbose-input");

        return new FpsOptions
        {
            Adaptive = adaptive,
            MaxAdaptiveFps = maxAdaptiveFps,
            TargetFps = targetFps,
            ForceGdi = forceGdi,
            ForceCpu = forceCpu,
            ForceGpu = forceGpu,
            RequestedEncW = requestedEncW,
            RequestedEncH = requestedEncH,
            VerboseInput = verboseInput,
        };
    }

    // "--key value" lookup over argv.
    private static string? GetArg(string[] a, string key)
    {
        for (int i = 0; i < a.Length - 1; i++)
            if (a[i] == key) return a[i + 1];
        return null;
    }
}
