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
	ui_tooltip = "The dark-scene lift fades to none above this luminance, so anything at or above it keeps its native brightness instead of being pushed higher. Compression is unaffected.";
	ui_category = "Governor";
> = 10.0;

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
	ui_tooltip = "Restores contrast lost when shadows are lifted. Expands tonal separation about the lifted scene average, scaled by how hard the scene is being lifted and confined to the shadow region, so mean brightness and highlights/UI stay put. 0 = off.";
	ui_category = "Tone curve";
> = 0.1;

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
	float3 src  = tex2D(samplerBackBuffer, uv).rgb;
	float4 ad   = tex2Dfetch(samplerAdapt, int2(0, 0));
	float adPeak = ad.x;
	float adFall = ad.y;

	float targetFall = DisplayMaxFALL * (HeadroomPercent * 0.01);
	float ratio      = targetFall / max(adFall, 0.01);
	float g = (ratio < 1.0) ? max(ratio, MinGain)
	                        : min(pow(ratio, LiftStrength), MaxGain);

	float3 lin  = decode_to_nits(src, csp);
	float  Ysrc = luminance(lin, csp);

	// Highlight-protection weight: 1 in shadow, fading to 0 at/above the knee so the
	// UI and sunlit highlights keep their native brightness.
	float w     = 1.0 - smoothstep(HighlightProtect * 0.3, HighlightProtect, Ysrc);
	float gEff  = (g > 1.0) ? lerp(1.0, g, w) : g;
	float Ylift = Ysrc * gEff;

	// Dynamic contrast: lifting shadows flattens them, so expand tonal separation
	// about the lifted scene average. Strength tracks the lift amount and is confined
	// to the shadow region by the same weight, preserving mean luma and highlights.
	float Yc = Ylift;
	if (DynamicContrast > 0.0 && g > 1.0)
	{
		float strength = DynamicContrast * saturate((g - 1.0) / max(MaxGain - 1.0, 0.01)) * w;
		float pivot    = nits_to_pq(max(adFall * g, 0.1));
		float p        = nits_to_pq(Ylift);
		Yc = pq_to_nits(saturate(pivot + (p - pivot) * (1.0 + strength)));
	}

	float Yt = UseHighlightRolloff ? bt2390_eetf(Yc, adPeak * min(g, 1.0), DisplayPeak, DisplayBlack) : Yc;

	float3 outNits = lin * (Yt / max(Ysrc, 1e-4));
	float3 outc    = lerp(src, encode_from_nits(outNits, csp), Strength);

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
	pass Apply   { VertexShader = VS_Post; PixelShader = PS_Tonemap; }
}
