// =============================================================================
//  DVHDR — Dynamic Dolby-Vision-style tonemapping for ReShade 6.5+
//
//  Sits on top of RenoDX's static HDR output (scRGB FP16 or HDR10 PQ) and
//  performs runtime dynamic display-mapping: it measures each frame's luminance
//  with a compute-shader histogram, smooths the statistics over time, then
//  governs the frame-average light level to stay within the panel's MaxFALL
//  (taming OLED/QD-OLED ABL "pumping") while a BT.2390 rolloff keeps sparse
//  highlights reaching toward the display's true peak.
//
//  Self-contained: no ReShade.fxh dependency.
// =============================================================================

#ifndef DVHDR_ENABLE_OVERLAY
	#define DVHDR_ENABLE_OVERLAY 1   // set 0 if the integer-sampler overlay fails to compile
#endif

#ifndef DVHDR_ANALYZE_STRIDE
	#define DVHDR_ANALYZE_STRIDE 2   // sample every Nth pixel for the histogram (perf vs accuracy)
#endif

#ifndef DVHDR_LC_MAX_RADIUS
	#define DVHDR_LC_MAX_RADIUS 24   // upper bound on the local-contrast blur radius (perf ceiling)
#endif

#define DVHDR_BINS        256
#define DVHDR_GROUP       16
#define DVHDR_STEP        (DVHDR_ANALYZE_STRIDE * DVHDR_GROUP)
#define DVHDR_DISPATCH_X  ((BUFFER_WIDTH  + DVHDR_STEP - 1) / DVHDR_STEP)
#define DVHDR_DISPATCH_Y  ((BUFFER_HEIGHT + DVHDR_STEP - 1) / DVHDR_STEP)

#ifndef BUFFER_COLOR_SPACE
	#define BUFFER_COLOR_SPACE 0
#endif

static const int CSP_SCRGB = 1;
static const int CSP_HDR10 = 2;

// ---------------------------------------------------------------------------
//  User controls
// ---------------------------------------------------------------------------

uniform int ColorSpaceOverride <
	ui_type = "combo";
	ui_label = "Source colour space";
	ui_items = "Auto (detect)\0scRGB FP16\0HDR10 PQ\0";
	ui_tooltip = "Your RenoDX install outputs scRGB FP16. Leave on Auto unless detection misbehaves.";
	ui_category = "Source";
> = 0;

uniform float DisplayPeak <
	ui_type = "slider";
	ui_label = "Display peak (nits)";
	ui_min = 100.0; ui_max = 4000.0; ui_step = 10.0;
	ui_tooltip = "Your panel's true peak luminance. Matches RenoDX toneMapPeakNits.";
	ui_category = "Display";
> = 1300.0;

uniform float DisplayMaxFALL <
	ui_type = "slider";
	ui_label = "Display MaxFALL (nits)";
	ui_min = 50.0; ui_max = 1000.0; ui_step = 5.0;
	ui_tooltip = "Maximum sustained Frame-Average Light Level your panel allows before its ABL throttles the image.";
	ui_category = "Display";
> = 265.0;

uniform float DisplayBlack <
	ui_type = "slider";
	ui_label = "Display black floor (nits)";
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.001;
	ui_tooltip = "Minimum luminance of the panel. 0 for OLED.";
	ui_category = "Display";
> = 0.0;

uniform float BlackLift <
	ui_type = "slider";
	ui_label = "Black-level lift (nits)";
	ui_min = 0.0; ui_max = 5.0; ui_step = 0.00001;
	ui_tooltip = "Raises the black floor to this many nits while pulling the ceiling (MaxCLL) back down by the same amount, so the result stays exactly within [BlackLift, Display peak] and nothing clips. Pure black becomes a faint neutral grey. For panels that crush detail right at the bottom of their range / cannot cleanly drive near-zero. 0 = disabled.";
	ui_category = "Display";
> = 0.00248;

uniform float HeadroomPercent <
	ui_type = "slider";
	ui_label = "FALL headroom (%)";
	ui_min = 50.0; ui_max = 100.0; ui_step = 1.0;
	ui_tooltip = "Target frame-average as a percentage of MaxFALL. Lower = safer margin against ABL.";
	ui_category = "Governor";
> = 90.0;

uniform float MinGain <
	ui_type = "slider";
	ui_label = "Max compression";
	ui_min = 0.05; ui_max = 1.0; ui_step = 0.01;
	ui_tooltip = "Lower bound of the global gain. The strongest the governor may dim a too-bright scene.";
	ui_category = "Governor";
> = 0.25;

uniform float LiftStrength <
	ui_type = "slider";
	ui_label = "Dark-scene lift";
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_tooltip = "How much to brighten scenes that sit below the FALL target. 0 = pure highlight protection (no lift).";
	ui_category = "Governor";
> = 0.25;

uniform float MaxGain <
	ui_type = "slider";
	ui_label = "Max lift gain";
	ui_min = 1.0; ui_max = 4.0; ui_step = 0.05;
	ui_tooltip = "Upper bound of the global gain when lifting dim scenes.";
	ui_category = "Governor";
> = 1.5;

uniform float HighlightProtect <
	ui_type = "slider";
	ui_label = "Protect highlights above (nits)";
	ui_min = 1.0; ui_max = 80.0; ui_step = 1.0;
	ui_tooltip = "The dark-scene lift fades to none above this luminance, so anything at or above it keeps its native brightness instead of being pushed higher. The rolloff is smooth in PQ across the whole range below it. Compression is unaffected.";
	ui_category = "Governor";
> = 80.0;

uniform float ShadowToe <
	ui_type = "slider";
	ui_label = "Shadow toe (nits)";
	ui_min = 0.0; ui_max = 5.0; ui_step = 0.01;
	ui_tooltip = "Below this luminance the lift eases back to identity slope, so the deepest blacks keep the source's own gradation instead of being amplified by the gain into a contouring 'cliff' just above black. 0 = off.";
	ui_category = "Governor";
> = 0.25;

uniform float PeakPercentile <
	ui_type = "slider";
	ui_label = "Peak percentile";
	ui_min = 90.0; ui_max = 100.0; ui_step = 0.05;
	ui_tooltip = "Luminance percentile treated as the scene peak. Below 100 ignores stray firefly pixels.";
	ui_category = "Governor";
> = 99.7;

uniform float AttackMs <
	ui_type = "slider";
	ui_label = "Attack (ms)";
	ui_min = 1.0; ui_max = 2000.0; ui_step = 1.0;
	ui_tooltip = "Time constant when the scene brightens. Short = react quickly to protect against ABL.";
	ui_category = "Temporal";
> = 80.0;

uniform float ReleaseMs <
	ui_type = "slider";
	ui_label = "Release (ms)";
	ui_min = 1.0; ui_max = 5000.0; ui_step = 1.0;
	ui_tooltip = "Time constant when the scene darkens. Long = settle gently, avoid pumping.";
	ui_category = "Temporal";
> = 600.0;

uniform float DynamicContrast <
	ui_type = "slider";
	ui_label = "Dynamic contrast";
	ui_min = 0.0; ui_max = 1.5; ui_step = 0.01;
	ui_tooltip = "Macro contrast — a smooth S-curve applied to the low-pass base about the lifted scene average, shaping large-scale tonal separation without touching the per-pixel detail. Scaled by the lift amount and confined to the shadow region. 0 = off.";
	ui_category = "Tone curve";
> = 0.2;

uniform float DetailGain <
	ui_type = "slider";
	ui_label = "Detail gain (contrast preserve)";
	ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
	ui_tooltip = "The per-pixel perceptual contrast (everything finer than the detail radius) is re-added onto the lifted base at this gain. 1.0 = preserve exactly, so lightened pixels keep their contrast instead of flattening; >1 = enhance/sharpen; 0 = off (flat lift). This is the contrast-preserving local tonemap.";
	ui_category = "Tone curve";
> = 1.0;

uniform float DetailRadius <
	ui_type = "slider";
	ui_label = "Detail radius";
	ui_min = 1.0; ui_max = 24.0; ui_step = 1.0;
	ui_tooltip = "Base/detail split radius (pixels) — the low-pass separating 'base' tone from 'detail'. Larger = smoother base, more detail preserved, but softer halos at strong edges; smaller = finer, less halo. Higher radii cost more.";
	ui_category = "Tone curve";
> = 12.0;

uniform float DetailBias <
	ui_type = "slider";
	ui_label = "Detail bias (halo guard)";
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_tooltip = "Damps below-base (darker-than-neighbourhood) detail to resist haloing at strong edges. 0.0 = symmetric (true contrast preservation); 1.0 = only re-add brighter-than-base detail.";
	ui_category = "Tone curve";
> = 0.0;

uniform float LiftLocality <
	ui_type = "slider";
	ui_label = "Lift locality";
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_tooltip = "Where the dark-scene lift takes its reference. 0 = region: lifts dark areas but leaves a dark pixel amid brighter content alone (preserves local contrast). 1 = per-pixel: every dark tone lifts (more visible on mixed content, flattens local contrast). 0.5 = balance.";
	ui_category = "Tone curve";
> = 0.0;

uniform bool UseHighlightRolloff <
	ui_label = "BT.2390 highlight rolloff";
	ui_tooltip = "Smoothly compress highlights above the display peak instead of clipping them.";
	ui_category = "Tone curve";
> = true;

uniform float Strength <
	ui_type = "slider";
	ui_label = "Effect strength";
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_tooltip = "Blend between the original RenoDX image and the dynamically tonemapped result.";
	ui_category = "Tone curve";
> = 1.0;

uniform float ChromaCorrect <
	ui_type = "slider";
	ui_label = "Chroma correction (DICE)";
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_tooltip = "ICtCp recombine: as luminance is lifted or compressed, chroma is scaled to hold perceived saturation through the curve, so colours stay vivid and hue-true instead of washing toward white. 1.0 = full preservation, 0.0 = intensity only.";
	ui_category = "Color";
> = 1.0;

uniform float DitherStrength <
	ui_type = "slider";
	ui_label = "Dither strength (code steps)";
	ui_min = 0.0; ui_max = 4.0; ui_step = 0.1;
	ui_tooltip = "Blue-noise output dither amplitude in 10-bit code steps. Breaks panel quantisation banding at all levels, in luma and chroma. 0 = off. ~1-2 typical; raise for 8-bit panels, lower for 12-bit.";
	ui_category = "Dither";
> = 1.5;

uniform float DitherActivity <
	ui_type = "slider";
	ui_label = "Dither activity";
	ui_min = 0.0005; ui_max = 0.02; ui_step = 0.0005;
	ui_tooltip = "Local PQ variance at which the dither reaches full strength. Smaller = more sensitive (engages on fainter gradients); larger = only stronger gradients are dithered.";
	ui_category = "Dither";
> = 0.002;

uniform float DitherFloor <
	ui_type = "slider";
	ui_label = "Dither floor";
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
	ui_tooltip = "Baseline dither fraction kept even on near-flat areas. Raise toward 1 for full-frame dithering if wide flat bands persist; lower for cleaner flat fields.";
	ui_category = "Dither";
> = 0.4;

uniform float DebandThreshold <
	ui_type = "slider";
	ui_label = "Deband threshold (code steps)";
	ui_min = 0.0; ui_max = 8.0; ui_step = 0.1;
	ui_tooltip = "Analytic debanding sensitivity, in 10-bit PQ code steps. 0 = off. A region that is flat but stepped (neighbours within this many code steps) is reconstructed smooth; detail and edges beyond it are kept. ~1.5-3 typical; higher catches coarser bands but can soften faint detail.";
	ui_category = "Deband";
> = 3.0;

uniform float DebandRange <
	ui_type = "slider";
	ui_label = "Deband range (pixels)";
	ui_min = 1.0; ui_max = 48.0; ui_step = 1.0;
	ui_tooltip = "Deband sample radius in pixels. Larger flattens broader bands but costs a little more and can soften if pushed too far.";
	ui_category = "Deband";
> = 16.0;

uniform int DebugOverlay <
	ui_type = "combo";
	ui_label = "Debug overlay";
	ui_items = "Off\0Histogram + markers\0";
	ui_tooltip = "Bottom-left: luminance histogram (PQ-spaced). Green = current FALL, cyan = FALL target, red = scene peak.";
	ui_category = "Debug";
> = 0;

uniform float frametime < source = "frametime"; >;

// ---------------------------------------------------------------------------
//  Resources
// ---------------------------------------------------------------------------

texture BackBufferTex : COLOR;
sampler samplerBackBuffer { Texture = BackBufferTex; };

// Luminance histogram (R32I, one row of bins) — written by compute via atomics.
texture texHistogram { Width = DVHDR_BINS; Height = 1; Format = R32I; };
storage2D<int> stHistogram { Texture = texHistogram; };
#if DVHDR_ENABLE_OVERLAY
sampler2D<int> sampHistogram { Texture = texHistogram; };
#endif

// Persisted adaptation state: x=smoothed peak nits, y=smoothed FALL nits,
//                             z=raw FALL nits (debug), w=max bin count (overlay).
texture texAdapt { Width = 1; Height = 1; Format = RGBA32F; };
storage2D<float4> stAdapt { Texture = texAdapt; };
sampler samplerAdapt { Texture = texAdapt; };

// Separable luminance blur (PQ-encoded) — neighbourhood mean for local contrast.
texture texLumaH     { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler sampLumaH    { Texture = texLumaH; };
texture texLumaBlur  { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R16F; };
sampler sampLumaBlur { Texture = texLumaBlur; };

// ---------------------------------------------------------------------------
//  Colour-space helpers
// ---------------------------------------------------------------------------

static const float PQ_m1 = 0.1593017578125;
static const float PQ_m2 = 78.84375;
static const float PQ_c1 = 0.8359375;
static const float PQ_c2 = 18.8515625;
static const float PQ_c3 = 18.6875;

float3 PQ_to_linear(float3 E)
{
	float3 Ep  = pow(max(E, 0.0), 1.0 / PQ_m2);
	float3 num = max(Ep - PQ_c1, 0.0);
	float3 den = PQ_c2 - PQ_c3 * Ep;
	return pow(num / max(den, 1e-6), 1.0 / PQ_m1);
}

float3 linear_to_PQ(float3 L)
{
	float3 Lm  = pow(max(L, 0.0), PQ_m1);
	float3 num = PQ_c1 + PQ_c2 * Lm;
	float3 den = 1.0 + PQ_c3 * Lm;
	return pow(num / den, PQ_m2);
}

float nits_to_pq(float nits)
{
	return linear_to_PQ(saturate(nits / 10000.0).xxx).x;
}

float pq_to_nits(float e)
{
	return PQ_to_linear(saturate(e).xxx).x * 10000.0;
}

int get_csp()
{
	if (ColorSpaceOverride == 1) return CSP_SCRGB;
	if (ColorSpaceOverride == 2) return CSP_HDR10;
	return (BUFFER_COLOR_SPACE == 3) ? CSP_HDR10 : CSP_SCRGB; // Auto; scRGB is the safe default
}

float3 decode_to_nits(float3 c, int csp)
{
	if (csp == CSP_HDR10) return PQ_to_linear(saturate(c)) * 10000.0;
	return c * 80.0; // scRGB: 1.0 == 80 nits
}

float3 encode_from_nits(float3 n, int csp)
{
	if (csp == CSP_HDR10) return linear_to_PQ(saturate(n / 10000.0));
	return n / 80.0;
}

float luminance(float3 n, int csp)
{
	if (csp == CSP_HDR10) return dot(max(n, 0.0), float3(0.2627, 0.6780, 0.0593)); // BT.2020
	return dot(max(n, 0.0), float3(0.2126, 0.7152, 0.0722));                       // BT.709
}

// BT.2390-8 EETF — maps source luminance into [black, peak] with a Hermite knee.
float bt2390_eetf(float L, float srcPeak, float dstPeak, float dstBlack)
{
	srcPeak = max(srcPeak, dstPeak); // if the scene never exceeds the display, this is identity
	float e    = nits_to_pq(L);
	float sMax = nits_to_pq(srcPeak);
	float sMin = 0.0;                 // source black
	float dMax = nits_to_pq(dstPeak);
	float dMin = nits_to_pq(dstBlack);

	float denom  = max(sMax - sMin, 1e-5);
	float E1     = saturate((e - sMin) / denom);
	float maxLum = (dMax - sMin) / denom;
	float minLum = (dMin - sMin) / denom;
	float KS     = 1.5 * maxLum - 0.5;

	float E2 = E1;
	if (E1 > KS && KS < 1.0)
	{
		float T  = (E1 - KS) / (1.0 - KS);
		float T2 = T * T;
		float T3 = T2 * T;
		E2 = (2.0 * T3 - 3.0 * T2 + 1.0) * KS
		   + (T3 - 2.0 * T2 + T) * (1.0 - KS)
		   + (-2.0 * T3 + 3.0 * T2) * maxLum;
	}

	float E3   = E2 + minLum * pow(max(1.0 - E2, 0.0), 4.0);
	float Eout = E3 * denom + sMin;
	return pq_to_nits(Eout);
}

float bin_to_nits(int i)
{
	return pq_to_nits((i + 0.5) / float(DVHDR_BINS));
}

// Interleaved Gradient Noise — Jorge Jimenez. Cheap blue-noise-like pattern
// from screen-space pixel coordinates, no texture required. Output is in
// [0, 1] with good spectral properties for dither.
float ign(float2 pos)
{
	return frac(52.9829189 * frac(dot(pos, float2(0.06711056, 0.00583715))));
}

// ---------------------------------------------------------------------------
//  ICtCp (BT.2100) — DICE-style recombine. The operator's intensity change
//  (Ysrc -> Yt) is applied as a PQ-domain shift on the true ICtCp intensity,
//  then chroma is scaled to hold perceived saturation through the curve. ICtCp
//  is defined on BT.2020 primaries, so scRGB (709) is converted in and back out.
// ---------------------------------------------------------------------------

static const float3x3 RGB709_to_2020 = float3x3(
	0.627404, 0.329283, 0.043313,
	0.069097, 0.919540, 0.011362,
	0.016391, 0.088013, 0.895596);
static const float3x3 RGB2020_to_709 = float3x3(
	 1.660491, -0.587641, -0.072850,
	-0.124550,  1.132900, -0.008349,
	-0.018151, -0.100579,  1.118730);
static const float3x3 RGB2020_to_LMS = float3x3(
	1688.0/4096.0,  2146.0/4096.0,   262.0/4096.0,
	 683.0/4096.0,  2951.0/4096.0,   462.0/4096.0,
	  99.0/4096.0,   309.0/4096.0,  3688.0/4096.0);
static const float3x3 LMS_to_RGB2020 = float3x3(
	 3.4366066943, -2.5064521187,  0.0698454243,
	-0.7913295556,  1.9836004518, -0.1922708962,
	-0.0259498997, -0.0989137147,  1.1248636144);
static const float3x3 LMSp_to_ICtCp = float3x3(
	0.5,             0.5,             0.0,
	6610.0/4096.0, -13613.0/4096.0,  7003.0/4096.0,
	17933.0/4096.0, -17390.0/4096.0,  -543.0/4096.0);
static const float3x3 ICtCp_to_LMSp = float3x3(
	1.0,  0.0086090370,  0.1110296250,
	1.0, -0.0086090370, -0.1110296250,
	1.0,  0.5600313357, -0.3206271479);

float3 dice_recombine(float3 linNits, float Ysrc, float Yt, int csp, float chromaCorrect)
{
	float3 rgb2020 = (csp == CSP_HDR10) ? linNits : mul(RGB709_to_2020, linNits);
	float3 lms     = mul(RGB2020_to_LMS, max(rgb2020, 0.0));
	float3 lmsp    = linear_to_PQ(lms / 10000.0);
	float3 ictcp   = mul(LMSp_to_ICtCp, lmsp);

	float Isrc      = ictcp.x;
	float pqDelta   = nits_to_pq(Yt) - nits_to_pq(max(Ysrc, 1e-4));
	float Idst      = saturate(Isrc + pqDelta);
	float chromaScl = lerp(1.0, Idst / max(Isrc, 1e-4), chromaCorrect);

	ictcp.x   = Idst;
	ictcp.yz *= chromaScl;

	float3 lmsp2   = mul(ICtCp_to_LMSp, ictcp);
	float3 lms2    = PQ_to_linear(saturate(lmsp2)) * 10000.0;
	float3 out2020 = mul(LMS_to_RGB2020, lms2);
	float3 outNits = (csp == CSP_HDR10) ? out2020 : mul(RGB2020_to_709, out2020);
	return max(outNits, 0.0);
}

// ---------------------------------------------------------------------------
//  Source debanding — reconstruct quantised gradients before the lift can
//  amplify them. Per channel in PQ: gather neighbours at two IGN-rotated radii;
//  a flat-but-stepped neighbourhood (max deviation below DebandThreshold code
//  steps) is averaged smooth; genuine detail / edges are kept. Threshold IS the
//  detector.
// ---------------------------------------------------------------------------

float3 src_to_pq(float3 c, int csp) { return linear_to_PQ(saturate(decode_to_nits(c, csp) / 10000.0)); }
float3 pq_to_src(float3 p, int csp) { return encode_from_nits(PQ_to_linear(saturate(p)) * 10000.0, csp); }

float3 deband_source(float2 uv, float2 pos, float2 ts, int csp)
{
	float3 c   = src_to_pq(tex2D(samplerBackBuffer, uv).rgb, csp);
	float  thr = DebandThreshold / 1023.0;
	float3 sum = c;
	float3 mx  = float3(0.0, 0.0, 0.0);

	[unroll]
	for (int i = 1; i <= 2; i++)
	{
		float  ang = ign(pos + float2(i * 41.0, i * 23.0)) * 6.2831853;
		float  r   = DebandRange * (float(i) / 2.0);
		float2 d   = float2(cos(ang), sin(ang)) * r * ts;
		float2 q   = float2(-d.y, d.x);
		float3 s0 = src_to_pq(tex2D(samplerBackBuffer, uv + d).rgb, csp);
		float3 s1 = src_to_pq(tex2D(samplerBackBuffer, uv - d).rgb, csp);
		float3 s2 = src_to_pq(tex2D(samplerBackBuffer, uv + q).rgb, csp);
		float3 s3 = src_to_pq(tex2D(samplerBackBuffer, uv - q).rgb, csp);
		sum += s0 + s1 + s2 + s3;
		mx   = max(mx, max(max(abs(s0 - c), abs(s1 - c)), max(abs(s2 - c), abs(s3 - c))));
	}

	float3 avg = sum / 9.0;
	float3 t   = saturate(mx / max(thr, 1e-6));
	return pq_to_src(lerp(avg, c, t), csp);
}

// ---------------------------------------------------------------------------
//  Pass 1 — clear histogram
// ---------------------------------------------------------------------------

void CS_Clear(uint3 id : SV_DispatchThreadID)
{
	if (id.x < uint(DVHDR_BINS))
		tex2Dstore(stHistogram, int2(int(id.x), 0), 0);
}

// ---------------------------------------------------------------------------
//  Pass 2 — accumulate luminance histogram
// ---------------------------------------------------------------------------

void CS_Analyze(uint3 id : SV_DispatchThreadID)
{
	int2 px = int2(id.xy) * DVHDR_ANALYZE_STRIDE;
	if (px.x >= BUFFER_WIDTH || px.y >= BUFFER_HEIGHT)
		return;

	int csp  = get_csp();
	float3 c = tex2Dfetch(samplerBackBuffer, px).rgb;
	float Y  = luminance(decode_to_nits(c, csp), csp);

	int bin = clamp(int(nits_to_pq(Y) * (DVHDR_BINS - 1) + 0.5), 0, DVHDR_BINS - 1);
	atomicAdd(stHistogram, int2(bin, 0), 1);
}

// ---------------------------------------------------------------------------
//  Pass 3 — reduce histogram to stats + temporal adaptation
// ---------------------------------------------------------------------------

void CS_Adapt(uint3 id : SV_DispatchThreadID)
{
	float total   = 0.0;
	float sumNits = 0.0;
	float maxBin  = 1.0;

	[loop]
	for (int i = 0; i < DVHDR_BINS; i++)
	{
		float cnt = float(tex2Dfetch(stHistogram, int2(i, 0)));
		total   += cnt;
		sumNits += cnt * bin_to_nits(i);
		maxBin   = max(maxBin, cnt);
	}

	float fall = sumNits / max(total, 1.0);

	float allow = total * (1.0 - PeakPercentile * 0.01);
	float acc   = 0.0;
	int   pidx  = DVHDR_BINS - 1;
	[loop]
	for (int j = DVHDR_BINS - 1; j >= 0; j--)
	{
		acc += float(tex2Dfetch(stHistogram, int2(j, 0)));
		if (acc >= allow) { pidx = j; break; }
	}
	float peak = bin_to_nits(pidx);

	float4 prev  = tex2Dfetch(stAdapt, int2(0, 0));
	float  pPeak = prev.x;
	float  pFall = prev.y;
	if (pFall <= 0.0001) pFall = fall; // first-frame snap, no flash
	if (pPeak <= 0.0001) pPeak = peak;

	float aUp = saturate(1.0 - exp(-frametime / max(AttackMs,  1.0)));
	float aDn = saturate(1.0 - exp(-frametime / max(ReleaseMs, 1.0)));

	float sFall = lerp(pFall, fall, (fall > pFall) ? aUp : aDn);
	float sPeak = lerp(pPeak, peak, (peak > pPeak) ? aUp : aDn);

	tex2Dstore(stAdapt, int2(0, 0), float4(sPeak, sFall, fall, maxBin));
}

// ---------------------------------------------------------------------------
//  Pass 3b — separable luminance blur (neighbourhood mean for local contrast)
// ---------------------------------------------------------------------------

float pq_luma_at(int2 px, int csp)
{
	float3 c = tex2Dfetch(samplerBackBuffer, px).rgb;
	return nits_to_pq(luminance(decode_to_nits(c, csp), csp));
}

float PS_BlurH(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	int  csp = get_csp();
	int2 px  = int2(pos.xy);
	if (DetailGain <= 0.0)
		return pq_luma_at(px, csp); // feature off — pass per-pixel luma through untouched

	int   R     = clamp(int(DetailRadius + 0.5), 1, DVHDR_LC_MAX_RADIUS);
	float sigma = max(R * 0.5, 1.0);
	float sum = 0.0, wsum = 0.0;
	[loop]
	for (int d = -R; d <= R; d++)
	{
		int2  sp  = int2(clamp(px.x + d, 0, BUFFER_WIDTH - 1), px.y);
		float wgt = exp(-0.5 * float(d * d) / (sigma * sigma));
		sum  += pq_luma_at(sp, csp) * wgt;
		wsum += wgt;
	}
	return sum / max(wsum, 1e-5);
}

float PS_BlurV(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	int2 px = int2(pos.xy);
	if (DetailGain <= 0.0)
		return tex2Dfetch(sampLumaH, px).r;

	int   R     = clamp(int(DetailRadius + 0.5), 1, DVHDR_LC_MAX_RADIUS);
	float sigma = max(R * 0.5, 1.0);
	float sum = 0.0, wsum = 0.0;
	[loop]
	for (int d = -R; d <= R; d++)
	{
		int2  sp  = int2(px.x, clamp(px.y + d, 0, BUFFER_HEIGHT - 1));
		float wgt = exp(-0.5 * float(d * d) / (sigma * sigma));
		sum  += tex2Dfetch(sampLumaH, sp).r * wgt;
		wsum += wgt;
	}
	return sum / max(wsum, 1e-5);
}

// ---------------------------------------------------------------------------
//  Pass 4 — apply dynamic tonemap
// ---------------------------------------------------------------------------

void VS_Post(in uint id : SV_VertexID, out float4 pos : SV_Position, out float2 uv : TEXCOORD)
{
	uv  = float2((id == 2) ? 2.0 : 0.0, (id == 1) ? 2.0 : 0.0);
	pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

float4 PS_Tonemap(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	int csp     = get_csp();
	float3 src  = (DebandThreshold > 0.0)
		? deband_source(uv, pos.xy, float2(1.0 / BUFFER_WIDTH, 1.0 / BUFFER_HEIGHT), csp)
		: tex2D(samplerBackBuffer, uv).rgb;
	float4 ad   = tex2Dfetch(samplerAdapt, int2(0, 0));
	float adPeak = ad.x;
	float adFall = ad.y;

	float targetFall = DisplayMaxFALL * (HeadroomPercent * 0.01);
	float ratio      = targetFall / max(adFall, 0.01);
	float g = (ratio < 1.0) ? max(ratio, MinGain)
	                        : min(pow(ratio, LiftStrength), MaxGain);

	float3 lin  = decode_to_nits(src, csp);
	float  Ysrc = luminance(lin, csp);

	// Contrast-preserving lift via base/detail separation. The governor lift and
	// the macro S-curve act on a low-pass BASE only; the per-pixel detail is
	// re-added at full amplitude afterward, so the local slope of the tone curve
	// for detail finer than the base radius is forced back to 1 — lightened
	// pixels keep their contrast instead of being flattened by the curve. All in
	// PQ; we return to linear light once, at the recombine.
	float pqSrc    = nits_to_pq(Ysrc);
	float pqBase   = tex2D(sampLumaBlur, uv).r;        // low-pass luma (PQ); == pqSrc when DetailGain <= 0
	float pqRef    = lerp(pqBase, pqSrc, saturate(LiftLocality)); // 0 = region, 1 = per-pixel
	float detail   = pqSrc - pqRef;                   // per-pixel perceptual contrast
	float refNits  = pq_to_nits(pqRef);

	// Upper rolloff (highlight protection): the lift fades to none toward
	// HighlightProtect. Lower rolloff (shadow toe): the lift fades back to
	// identity slope toward black, so the deepest blacks keep the source's own
	// gradation instead of being amplified by the gain into a contouring cliff
	// just above black. Both ease smoothly in PQ; their product gates the lift
	// and the contrast stages so the whole bottom of the curve stays coherent.
	float wShadow = (g > 1.0)
		? 1.0 - smoothstep(0.0, nits_to_pq(max(HighlightProtect, 1e-4)), pqRef)
		: 1.0;
	float wToe = (ShadowToe > 0.0) ? smoothstep(0.0, nits_to_pq(ShadowToe), pqRef) : 1.0;
	float w    = wShadow * wToe;

	float pqRefL = (g > 1.0) ? lerp(pqRef, nits_to_pq(refNits * g), w)
	                         : nits_to_pq(refNits * g);

	// Macro contrast — a smooth bipolar S-curve about the lifted scene average,
	// applied to the BASE only so it shapes large-scale tonal separation without
	// touching the detail we are about to restore.
	if (DynamicContrast > 0.0 && g > 1.0)
	{
		float strength = DynamicContrast * saturate((g - 1.0) / max(MaxGain - 1.0, 0.01)) * w;
		float pivot    = nits_to_pq(max(adFall * g, 0.1));
		float d        = pqRefL - pivot;
		pqRefL = saturate(pivot + d * (1.0 + strength * exp(-d * d * 12.0)));
	}

	// Re-inject the per-pixel detail at full amplitude: the local slope for
	// anything finer than the base radius returns to 1, so lightened pixels keep
	// their perceptual contrast instead of being flattened by the lift. DetailGain
	// = 1 preserves; > 1 enhances; 0 = flat lift. DetailBias damps below-base
	// detail for halo resistance (0 = symmetric, full preserve).
	float biased = (detail > 0.0) ? detail : detail * (1.0 - DetailBias);
	float pqOut  = saturate(pqRefL + biased * DetailGain);

	float Ylc = pq_to_nits(pqOut);

	float Yt = UseHighlightRolloff ? bt2390_eetf(Ylc, adPeak * min(g, 1.0), DisplayPeak, DisplayBlack) : Ylc;

	float3 outNits = dice_recombine(lin, Ysrc, Yt, csp, ChromaCorrect);
	float3 outc    = lerp(src, encode_from_nits(outNits, csp), Strength);

	// Black-level lift — applied as an absolute floor on the FINAL output, after
	// the Strength crossfade, so nothing (a partial-strength blend back toward
	// the untouched source, or the dynamic/local-contrast stages above) can sit
	// below it. Affine remap [0, DisplayPeak] -> [BlackLift, DisplayPeak] in
	// nits: peak-preserving (per-channel MaxCLL stays at DisplayPeak), the
	// darkest pixels rise to a faint neutral grey, and being affine (not a
	// ratio) it is safe on pure black. For panels that crush detail right at the
	// bottom of their range.
	if (BlackLift > 0.0)
	{
		float3 fn = decode_to_nits(outc, csp);
		outc = encode_from_nits(BlackLift + fn * (1.0 - BlackLift / max(DisplayPeak, 1.0)), csp);
	}

	// Output dither — break the panel's quantisation banding at all levels, in
	// luma AND chroma. Per-channel blue noise sized to one perceptual (PQ) code
	// step, so the amplitude tracks the quantiser at every level rather than only
	// in highlights. Gated by local neighbourhood activity in ANY channel, so
	// flat fields stay clean while every region containing gradation is broken
	// up. DitherStrength = 10-bit code steps; DitherActivity = PQ variance for
	// full strength; DitherFloor = baseline kept on near-flat areas.
	if (DitherStrength > 0.0)
	{
		float2 ts = float2(1.0 / float(BUFFER_WIDTH), 1.0 / float(BUFFER_HEIGHT));
		float3 pC = linear_to_PQ(saturate(decode_to_nits(src, csp) / 10000.0));
		float3 pL = linear_to_PQ(saturate(decode_to_nits(tex2D(samplerBackBuffer, uv + float2(-ts.x, 0.0)).rgb, csp) / 10000.0));
		float3 pR = linear_to_PQ(saturate(decode_to_nits(tex2D(samplerBackBuffer, uv + float2( ts.x, 0.0)).rgb, csp) / 10000.0));
		float3 pU = linear_to_PQ(saturate(decode_to_nits(tex2D(samplerBackBuffer, uv + float2(0.0, -ts.y)).rgb, csp) / 10000.0));
		float3 pD = linear_to_PQ(saturate(decode_to_nits(tex2D(samplerBackBuffer, uv + float2(0.0,  ts.y)).rgb, csp) / 10000.0));
		float3 dev = max(max(abs(pL - pC), abs(pR - pC)), max(abs(pU - pC), abs(pD - pC)));
		float  act  = max(dev.r, max(dev.g, dev.b));         // luma OR chroma variance, in PQ
		float  actF = lerp(DitherFloor, 1.0, saturate(act / max(DitherActivity, 1e-5)));
		float  lsb  = (DitherStrength / 1023.0) * actF;      // one PQ code step, scaled

		float3 noise = float3(ign(pos.xy),
		                      ign(pos.xy + float2(53.0, 17.0)),
		                      ign(pos.xy + float2(101.0, 71.0))) - 0.5;

		if (csp == CSP_HDR10)
		{
			outc = saturate(outc + noise * lsb);             // output is PQ — perturb directly
		}
		else
		{
			// scRGB: convert one PQ step to a linear-light delta at this level, so
			// the perturbation is perceptually ~1 step without clipping the gamut.
			float3 vN = max(decode_to_nits(outc, csp), 0.0);
			float3 pq = linear_to_PQ(saturate(vN / 10000.0));
			float3 dN = PQ_to_linear(saturate(pq + lsb)) * 10000.0 - vN;
			outc += noise * (dN / 80.0);
		}
	}

#if DVHDR_ENABLE_OVERLAY
	if (DebugOverlay == 1)
	{
		const float2 o0 = float2(24.0, BUFFER_HEIGHT - 24.0 - 180.0);
		const float2 o1 = float2(24.0 + DVHDR_BINS * 2.0, BUFFER_HEIGHT - 24.0);
		if (pos.x >= o0.x && pos.x < o1.x && pos.y >= o0.y && pos.y < o1.y)
		{
			int   bin   = clamp(int((pos.x - o0.x) / 2.0), 0, DVHDR_BINS - 1);
			float count = float(tex2Dfetch(sampHistogram, int2(bin, 0)));
			float h     = count / max(ad.w, 1.0);
			float yNorm = 1.0 - (pos.y - o0.y) / (o1.y - o0.y);

			int fallBin   = clamp(int(nits_to_pq(ad.z) * (DVHDR_BINS - 1) + 0.5), 0, DVHDR_BINS - 1);
			int targetBin = clamp(int(nits_to_pq(DisplayMaxFALL * (HeadroomPercent * 0.01)) * (DVHDR_BINS - 1) + 0.5), 0, DVHDR_BINS - 1);
			int peakBin   = clamp(int(nits_to_pq(adPeak) * (DVHDR_BINS - 1) + 0.5), 0, DVHDR_BINS - 1);

			float3 panel = (yNorm <= h) ? float3(0.85, 0.85, 0.85) : float3(0.05, 0.05, 0.05);
			if (bin == fallBin)   panel = float3(0.1, 1.0, 0.1);
			if (bin == targetBin) panel = float3(0.1, 0.8, 1.0);
			if (bin == peakBin)   panel = float3(1.0, 0.2, 0.2);

			outc = encode_from_nits(panel * 100.0, csp); // ~100 nit readable overlay
		}
	}
#endif

	return float4(outc, 1.0);
}

// ---------------------------------------------------------------------------

technique DVHDR <
	ui_label = "DVHDR — Dynamic Tonemapping";
	ui_tooltip = "Dolby-Vision-style dynamic display-mapping on top of RenoDX. Toggle off Performance Mode to tune.";
>
{
	pass Clear   { ComputeShader = CS_Clear<DVHDR_BINS, 1>;        DispatchSizeX = 1;                DispatchSizeY = 1; }
	pass Analyze { ComputeShader = CS_Analyze<DVHDR_GROUP, DVHDR_GROUP>; DispatchSizeX = DVHDR_DISPATCH_X; DispatchSizeY = DVHDR_DISPATCH_Y; }
	pass Adapt   { ComputeShader = CS_Adapt<1, 1>;                 DispatchSizeX = 1;                DispatchSizeY = 1; }
	pass BlurH   { VertexShader = VS_Post; PixelShader = PS_BlurH; RenderTarget = texLumaH; }
	pass BlurV   { VertexShader = VS_Post; PixelShader = PS_BlurV; RenderTarget = texLumaBlur; }
	pass Apply   { VertexShader = VS_Post; PixelShader = PS_Tonemap; }
}
