// Bromure AC — the Rooms stage's Metal effects (SwiftUI stitchable shaders).
//
// Compiled by build.sh into RoomEffects.metallib in the app's Resources
// (kept out of Sources/ so SwiftPM never tries to build it). Loaded with
// ShaderLibrary(url:); when it's missing the stage animates without it.
//
// `roomShockwave` is a colorEffect for an overlay drawn ON TOP of a zooming
// cell — never a distortion of the chat itself, whose AppKit-backed text
// views a layer effect can't rasterize. It paints a soft ring of light that
// expands from the click point and fades as the zoom settles.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 roomShockwave(float2 position, half4 color,
                                      float2 size, float2 origin,
                                      float progress, half4 tint) {
    // Distance from the click, in units of the view's diagonal.
    float diag = length(size);
    float d = distance(position, origin) / max(diag, 1.0);
    // The ring travels past the far corner by the end of the zoom.
    float radius = progress * 1.15;
    float width = 0.035 + 0.05 * progress;
    float ring = exp(-pow((d - radius) / width, 2.0));
    // A faint wake behind the ring, and everything fading out as it lands.
    float wake = smoothstep(radius, 0.0, d) * 0.12;
    float fade = pow(1.0 - clamp(progress, 0.0, 1.0), 1.4);
    float a = clamp((ring * 0.55 + wake) * fade, 0.0, 1.0);
    return half4(tint.rgb * half(a), half(a));
}
