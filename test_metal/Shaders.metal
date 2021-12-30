//
//  Shaders.metal
//  test_metal
//
//  Created by Minoru Harada on 2021/11/15.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float3 normal   [[attribute(VertexAttributeNormal)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float4 shadowPosition;
    float3 normal;
    float2 texCoord;
} ColorInOut;

vertex float4 vertex_zOnly(Vertex in [[stage_in]],
                           constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    float4 position = float4(in.position, 1.0);
    
    position = uniforms.projectionMatrix * uniforms.shadowViewMatrix * position;
    
    return position;
}

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    float4 position = float4(in.position, 1.0);
    float4 normal = float4(in.normal, 0);
    
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.shadowPosition = uniforms.projectionMatrix * uniforms.shadowViewMatrix * position;
    out.normal = (uniforms.modelViewMatrix * normal).xyz;
    out.texCoord = in.texCoord;

    return out;
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               texture2d<half> colorMap     [[ texture(TextureIndexColor)  ]],
                               depth2d<float>  shadowMap    [[ texture(TextureIndexShadow) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);
    constexpr sampler shadowSampler(coord::normalized,
                                    filter::linear,
                                    address::clamp_to_edge,
                                    compare_func::less);
    
    half4 colorSample = colorMap.sample(colorSampler, in.texCoord.xy);

    float2 xy = in.shadowPosition.xy / in.shadowPosition.w;
    xy = xy * 0.5 + 0.5;
    xy.y = 1 - xy.y;
    float shadowSample = shadowMap.sample(shadowSampler, xy);
    float currentSample = in.shadowPosition.z / in.shadowPosition.w - 1e-5;
    
    if (currentSample < shadowSample) {
        shadowSample = 1.0;
    } else {
        shadowSample = 0.01;
    }
    
    float3 L(0, 1, 1);
    float3 N = normalize(in.normal);
    float NdotL = saturate(dot(N, L));
    float intensity = saturate(0.1 + NdotL);

    return float4(intensity * shadowSample * colorSample);
}

