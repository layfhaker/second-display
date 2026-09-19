//! Command-line options, mirroring the C# `FpsOptions`.

#[derive(Debug, Clone)]
pub struct Options {
    /// Adaptive fps when `--fps` is absent or `auto`.
    pub adaptive: bool,
    /// `--max-fps` cap for adaptive mode.
    pub max_adaptive_fps: u32,
    /// Fixed target fps when not adaptive.
    pub target_fps: u32,
    pub force_gdi: bool,
    pub force_cpu: bool,
    pub force_gpu: bool,
    /// `--encode-width` (0 = same as capture).
    pub requested_enc_w: u32,
    /// `--encode-height` (0 = derive from width & capture aspect).
    pub requested_enc_h: u32,
    pub verbose_input: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            adaptive: true,
            max_adaptive_fps: 30,
            target_fps: 30,
            force_gdi: false,
            force_cpu: false,
            force_gpu: false,
            requested_enc_w: 0,
            requested_enc_h: 0,
            verbose_input: false,
        }
    }
}

impl Options {
    pub fn from_args(args: &[String]) -> Self {
        let mut o = Self::default();
        let fps_arg = get_arg(args, "--fps");
        o.adaptive = match fps_arg.as_deref() {
            None | Some("auto") | Some("") => true,
            Some(_) => false,
        };
        o.max_adaptive_fps = get_arg(args, "--max-fps")
            .and_then(|v| v.parse().ok())
            .filter(|&v: &u32| v > 0)
            .unwrap_or(30);
        o.target_fps = match &fps_arg {
            Some(v) if !o.adaptive => v.parse().ok().filter(|&v: &u32| v > 0).unwrap_or(30),
            _ => 30,
        };
        o.force_gdi = has_flag(args, "--gdi");
        o.force_cpu = has_flag(args, "--cpu");
        o.force_gpu = has_flag(args, "--gpu");
        o.requested_enc_w = get_arg(args, "--encode-width")
            .and_then(|v| v.parse().ok())
            .filter(|&v: &u32| v > 0)
            .unwrap_or(0);
        o.requested_enc_h = get_arg(args, "--encode-height")
            .and_then(|v| v.parse().ok())
            .filter(|&v: &u32| v > 0)
            .unwrap_or(0);
        o.verbose_input = has_flag(args, "--verbose-input");
        o
    }
}

pub fn has_flag(args: &[String], key: &str) -> bool {
    args.iter().any(|a| a == key)
}

/// "--key value" lookup over argv.
pub fn get_arg(args: &[String], key: &str) -> Option<String> {
    args.windows(2).find(|w| w[0] == key).map(|w| w[1].clone())
}
