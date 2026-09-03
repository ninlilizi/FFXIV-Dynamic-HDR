# DVHDR — Dynamic Tonemapping for ReShade

A ReShade 6.5+ effect that adds **dynamic, per-scene display-mapping on top of an existing HDR image**. It was built for Final Fantasy XIV running under [RenoDX](https://github.com/clshortfuse/renodx), but works after any HDR tonemapper that outputs scRGB FP16 or HDR10 PQ. But will work in reShade for any games that output in HDR.

## What it is

Static HDR tonemappers (RenoDX, in-game HDR, etc.) map the picture to a **fixed** peak — they don't react to scene content, and they don't account for your panel's **MaxFALL** (the sustained full-screen brightness limit that drives OLED/QD-OLED ABL "pumping"). DVHDR adds the missing dynamic layer:

- **Per-frame analysis** — a compute-shader histogram measures the scene's average light level (FALL) and a percentile peak.
- **Temporal adaptation** — those stats are smoothed with separate attack/release rates, snap on scene cuts and ignore tiny drifts, so scenes settle instead of flickering or pumping.
- **FALL governor** — scales the frame to keep its average within your MaxFALL, driven by a slow energy integrator so brief flashes keep their punch, while a **BT.2390 rolloff** lets sparse highlights still reach the panel's true peak.
- **Highlight-protected shadow lift** — gently raises shadows without touching the UI or bright detail (the lift fades out above a configurable luminance knee).
- **Dynamic contrast** — restores the local contrast a lift would otherwise flatten, scaled to how much was lifted, on an edge-aware base so nothing halos.
- **Colour integrity** — ICtCp chroma preservation that fades out in the deepest shadows, and a hue-preserving gamut clip.

## Why it exists

It emulates the **playback half of Dolby Vision** — the runtime display-mapping a DV display performs from dynamic metadata. The authoring half (per-scene metadata baked by a colourist) can't be reproduced for a game, so DVHDR synthesises the equivalent statistics live and maps accordingly. The practical payoff: bright scenes stay within MaxFALL (no ABL pumping), dark scenes gain visibility, and highlights keep their punch.

## Designed for use *after* HDR tonemapping

DVHDR is **not** an HDR conversion. It expects an HDR signal already on the wire and refines it. Run it **last in the load order**, downstream of RenoDX (or whatever produces your HDR output). It auto-detects the colour space and defaults safely to scRGB.

## Install

1. Drop `DVHDR.fx` into a folder on your ReShade `EffectSearchPaths` (the game folder, or `reshade-shaders\Shaders`).
2. Open the ReShade overlay, **Reload**, and enable **DVHDR — Dynamic Tonemapping** after your tonemapper.
3. Set **Display peak** and **Display MaxFALL** to your panel's specs. Toggle **Performance Mode off** to tune live.

## Key settings

| Setting | What it does |
| --- | --- |
| **Display peak / MaxFALL** | Your panel's true peak and sustained-average limits — the governor pivots on these. |
| **FALL headroom** | Target frame-average as a fraction of MaxFALL (lower = safer margin). |
| **Dark-scene lift** / **Protect highlights above** | How much shadows rise, and the luminance above which the lift fades out (UI/highlights stay native). |
| **Dynamic contrast** | Restores contrast lost to the lift, confined to the shadow region. |
| **Attack / Release** | React fast when brightening, settle slowly when darkening. |
| **Scene cut threshold / Deadband** | Snap the adaptation on a hard cut; ignore changes too small to matter. |
| **ABL window / Fast ceiling** | Compression follows sustained energy over this many seconds; the fast average only intervenes above the ceiling. |
| **Lift answers to** | Whether the shadow lift responds to the perceptual mean or the linear frame average. |
| **Base edge sigma** | Edge-aware base for the lift: larger radii without halos. 0 = plain Gaussian. |
| **Shadow desaturation / Gamut clip** | Keep lifted near-black noise grey; keep out-of-gamut colours on hue. |
| **Dither shape / strength** | Triangular noise at 2 code steps peak-to-peak, the textbook dither; uniform is the old behaviour. |
| **Wide gradation span / activity** | Read gradation across a wide span too, so slow ramps in bright skies and glows get full dither instead of the floor. |
| **Highlight boost** | Raise the dither amplitude toward the display peak, where panels step most coarsely. |
| **Temporal dither** | Walk the dither pattern each frame and flip its sign on alternate frames so pairs average out. |
| `DVHDR_BASE_DOWNSCALE` (preprocessor) | Resolution divisor of the lift base; 2 by default, 1 for full resolution. |
| **Debug overlay** | Live histogram with FALL / target / peak markers for tuning. |

## Requirements

ReShade 6.5+ with compute-shader support (DX11/DX12/Vulkan) and an upstream HDR signal.

## Limitations

The governor measures the whole frame, UI included, so very UI-heavy frames can read a higher average and compress slightly. UI is not masked.
