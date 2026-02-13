#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform sampler2D uTexture;
uniform vec2 uDisplacement;
uniform vec2 uDisplacementPos;
uniform float uBrushRadius;
uniform float uBrushIntensity;

float gaussianFalloff(float dist, float radius) {
    float normalizedDist = dist / radius;
    if (normalizedDist >= 1.0) return 0.0;
    return exp(-normalizedDist * normalizedDist * 4.0);
}

vec4 main(vec2 fragCoord) {
    vec2 uv = fragCoord / uSize;
    vec2 displacedUV = uv;
    
    vec2 toPoint = fragCoord - uDisplacementPos;
    float dist = length(toPoint);
    
    if (dist < uBrushRadius) {
        float falloff = gaussianFalloff(dist, uBrushRadius);
        vec2 normalizedDisp = length(uDisplacement) > 0.001 
            ? normalize(uDisplacement) 
            : vec2(0.0);
        vec2 displacement = normalizedDisp * length(uDisplacement) * falloff * uBrushIntensity;
        displacedUV -= displacement / uSize;
    }
    
    displacedUV = clamp(displacedUV, vec2(0.0), vec2(1.0));
    return texture(uTexture, displacedUV);
}
