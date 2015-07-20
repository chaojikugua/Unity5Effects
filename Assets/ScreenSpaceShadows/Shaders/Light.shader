Shader "Hidden/ScreenSpaceShadowLight" {
Properties {
}
SubShader {
    Tags { "RenderType"="Opaque" }
    Blend Off
    ZTest Always
    ZWrite Off
    Cull Off

CGINCLUDE
#if QUALITY_FAST
    #define MAX_MARCH 32
#elif QUALITY_HIGH
    #define MAX_MARCH 64
#else // QUALITY_MEDIUM
    #define MAX_MARCH 128
#endif

#define POINT
#include "UnityCG.cginc"
#include "UnityPBSLighting.cginc"
#include "UnityDeferredLibrary.cginc"
#include "Assets/GBufferUtils/Shaders/GBufferUtils.cginc"

sampler2D _BackDepth;
float4 _Position;
float4 _Color;
float4 _Params;
#define _Range          _Position.w
#define _RangeInvSq     (1.0/(_Range*_Range))
#define _InnerRadius    _Params.x
#define _CapsuleLength  _Params.y
#define _LightType      _Params.z


struct ia_out
{
    float4 vertex : POSITION;
    float3 normal : NORMAL;
};

struct vs_out
{
    float4 vertex : SV_POSITION;
    float4 screen_pos : TEXCOORD0;
};

struct ps_out
{
    half4 color : SV_Target0;
};


unity_v2f_deferred vert_point(ia_out v)
{
    v.vertex.xyz *= _Range;

    unity_v2f_deferred o;
    o.pos = mul(UNITY_MATRIX_MVP, v.vertex);
    o.uv = ComputeScreenPos(o.pos);
    o.ray = mul (UNITY_MATRIX_MV, v.vertex).xyz * float3(-1,-1,1);
    return o;
}


unity_v2f_deferred vert_line(ia_out v)
{
    return vert_point(v);
}



half3 CalcSphereLightToLight(float3 pos, float3 lightPos, float3 eyeVec, half3 normal, float sphereRad)
{
    half3 viewDir = -eyeVec;
    half3 r = reflect (viewDir, normal);

    float3 L = lightPos - pos;
    float3 centerToRay = dot (L, r) * r - L;
    float3 closestPoint = L + centerToRay * saturate(sphereRad / length(centerToRay));
    return normalize(closestPoint);
}

half3 CalcTubeLightToLight(float3 pos, float3 tubeStart, float3 tubeEnd, float3 eyeVec, half3 normal, float tubeRad)
{
    half3 N = normal;
    half3 viewDir = -eyeVec;
    half3 r = reflect (viewDir, normal);

    float3 L0		= tubeStart - pos;
    float3 L1		= tubeEnd - pos;
    float distL0	= length( L0 );
    float distL1	= length( L1 );
    
    float NoL0		= dot( L0, N ) / ( 2.0 * distL0 );
    float NoL1		= dot( L1, N ) / ( 2.0 * distL1 );
    float NoL		= ( 2.0 * clamp( NoL0 + NoL1, 0.0, 1.0 ) ) 
                    / ( distL0 * distL1 + dot( L0, L1 ) + 2.0 );
    
    float3 Ld			= L1 - L0;
    float RoL0		= dot( r, L0 );
    float RoLd		= dot( r, Ld );
    float L0oLd 	= dot( L0, Ld );
    float distLd	= length( Ld );
    float t			= ( RoL0 * RoLd - L0oLd ) 
                    / ( distLd * distLd - RoLd * RoLd );
    
    float3 closestPoint	= L0 + Ld * clamp( t, 0.0, 1.0 );
    float3 centerToRay	= dot( closestPoint, r ) * r - closestPoint;
    closestPoint		= closestPoint + centerToRay * clamp( tubeRad / length( centerToRay ), 0.0, 1.0 );
    float3 l				= normalize( closestPoint );
    return l;
}

void DeferredCalculateLightParams (
    unity_v2f_deferred i,
    out float3 outWorldPos,
    out float2 outUV,
    out half3 outLightDir,
    out float outAtten,
    out float outFadeDist)
{
    i.ray = i.ray * (_ProjectionParams.z / i.ray.z);
    float2 uv = i.uv.xy / i.uv.w;
    
    // read depth and reconstruct world position
    float depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, uv);
    depth = Linear01Depth (depth);
    float4 vpos = float4(i.ray * depth,1);
    float3 wpos = mul (_CameraToWorld, vpos).xyz;
    
    float3 lightPos = float3(_Object2World[0][3], _Object2World[1][3], _Object2World[2][3]);

    // Point light
    float3 tolight = wpos - lightPos;
    half3 lightDir = -normalize (tolight);
    
    float att = dot(tolight, tolight) * _RangeInvSq;
    float atten = tex2D (_LightTextureB0, att.rr).UNITY_ATTEN_CHANNEL;

    outWorldPos = wpos;
    outUV = uv;
    outLightDir = lightDir;
    outAtten = atten;
    outFadeDist = 0;
}



void distance_point_sphere(float3 ppos, float3 center, float radius,
    out float3 direction, out float distance)
{
    float3 diff = ppos - center;
    distance = length(diff)-radius;
    direction = normalize(diff);
}

void distance_point_capsule(float3 ppos, float3 pos1, float3 pos2, float radius,
    out float3 nearest, out float3 direction, out float distance)
{
    float3 d = pos2-pos1;
    float t = dot(ppos-pos1, pos2-pos1) / dot(d,d);
    nearest = pos1 + (pos2-pos1) * min(max(t, 0.0), 1.0);
    float3 diff = ppos-nearest;
    distance = length(diff) - radius;
    direction = normalize(diff);
}

// on d3d9, _CameraDepthTexture is bilinear-filtered. so we need to sample center of pixels.
#define HalfPixelSize ((_ScreenParams.zw-1.0)*0.5)

half4 frag_point(unity_v2f_deferred i) : SV_Target
{
    float3 wpos;
    float2 uv;
    float atten, fadeDist;
    UnityLight light = (UnityLight)0;
    DeferredCalculateLightParams (i, wpos, uv, light.dir, atten, fadeDist);
    
    float3 lightPos = float3(_Object2World[0][3], _Object2World[1][3], _Object2World[2][3]);
    float3 lightAxisX = normalize(float3(_Object2World[0][0], _Object2World[1][0], _Object2World[2][0]));
    float3 lightPos1 = lightPos + lightAxisX * _Range;
    float3 lightPos2 = lightPos - lightAxisX * _Range;


    float occlusion = 0.0;
    {
        float3 diff = wpos.xyz - _Position.xyz;
        float distance = length(diff);
        float march_step = distance / MAX_MARCH;
        float3 ray_dir = normalize(diff);
        for(int k=1; k<MAX_MARCH; ++k) {
            float adv = march_step * k;
            float3 ray_pos = _Position.xyz + ray_dir * adv;
            float4 ray_pos4 = mul(UNITY_MATRIX_VP, float4(ray_pos, 1.0));
            ray_pos4.y *= _ProjectionParams.x;
            float2 ray_coord = ray_pos4.xy / ray_pos4.w * 0.5 + 0.5 + HalfPixelSize;
            float ray_depth = ComputeDepth(ray_pos4);
            float ref_depth = GetDepth(ray_coord);
#if ENABLE_BACKDEPTH
#endif

            if(ray_depth > ref_depth) {
                occlusion += 3.0/MAX_MARCH;
            }
        }
    }
    if(occlusion >= 1.0) { discard; }



    half4 gbuffer0 = tex2D (_CameraGBufferTexture0, uv);
    half4 gbuffer1 = tex2D (_CameraGBufferTexture1, uv);
    half4 gbuffer2 = tex2D (_CameraGBufferTexture2, uv);

    light.color = _Color.rgb * atten;
    half3 baseColor = gbuffer0.rgb;
    half3 specColor = gbuffer1.rgb;
    half3 normalWorld = gbuffer2.rgb * 2 - 1;
    normalWorld = normalize(normalWorld);
    half oneMinusRoughness = gbuffer1.a;
    float3 eyeVec = normalize(wpos-_WorldSpaceCameraPos);

    if (_LightType == 1)
    {
        // tube light
        light.dir = CalcTubeLightToLight (wpos, lightPos1, lightPos2, eyeVec, normalWorld, _InnerRadius);
    }
    else
    {
        // Sphere light
        light.dir = CalcSphereLightToLight (wpos, lightPos, eyeVec, normalWorld, _InnerRadius);
    }

    half oneMinusReflectivity = 1 - SpecularStrength(specColor.rgb);
    light.ndotl = LambertTerm (normalWorld, light.dir);
    
    UnityIndirect ind;
    UNITY_INITIALIZE_OUTPUT(UnityIndirect, ind);
    ind.diffuse = 0;
    ind.specular = 0;

    half4 res = UNITY_BRDF_PBS (baseColor, specColor, oneMinusReflectivity, oneMinusRoughness, normalWorld, -eyeVec, light, ind);
    return res * max(1.0-occlusion, 0.0);
}

half4 frag_line(unity_v2f_deferred i) : SV_Target
{
    return frag_point(i); // todo
}
ENDCG

    // point light
    Pass {
        Fog { Mode Off }
        ZWrite Off
        ZTest Always
        Blend One One
        Cull Front

        CGPROGRAM
        #pragma target 3.0
        #pragma exclude_renderers nomrt
        #pragma multi_compile QUALITY_FAST QUALITY_MEDIUM QUALITY_HIGH
        #pragma multi_compile ___ ENABLE_BACKDEPTH
        #pragma vertex vert_point
        #pragma fragment frag_point
        ENDCG
    }

    // line light
    Pass {
        Fog { Mode Off }
        ZWrite Off
        ZTest Always
        Blend One One
        Cull Front

        CGPROGRAM
        #pragma target 3.0
        #pragma exclude_renderers nomrt
        #pragma multi_compile QUALITY_FAST QUALITY_MEDIUM QUALITY_HIGH
        #pragma multi_compile ___ ENABLE_BACKDEPTH
        #pragma vertex vert_line
        #pragma fragment frag_line
        ENDCG
    }
}
}