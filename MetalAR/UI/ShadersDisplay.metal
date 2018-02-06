//
//  Displayshaders.metal
//  MetalAR
//
//  Created by naru on 2018/02/01.
//  Copyright © 2017年 naru. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

struct Vertex2D {
    float2 position [[attribute(0)]];
    float2 texCoords [[attribute(1)]];
};

struct ProjectedVertex {
    float4 position [[position]];
    float2 texCoords;
};

vertex ProjectedVertex vertex_reshape(Vertex2D currentVertex [[stage_in]], constant float2x2 &scaling [[buffer(1)]]) {
    float2 position = scaling * currentVertex.position;
    ProjectedVertex out;
    out.position = float4(position, 0.0, 1.0);
    out.texCoords = currentVertex.texCoords;
    return out;
}

fragment half4 fragment_texture(ProjectedVertex in [[stage_in]], texture2d<float, access::sample> tex2d [[texture(0)]]) {
    constexpr sampler sampler2d(coord::normalized, filter::linear);
    return half4(tex2d.sample(sampler2d, in.texCoords));
}
