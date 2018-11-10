#version 450

#include "BasicCascadeShader.glsli"

const int MAX_POINT_LIGHTS = 2;                                                     
const int MAX_SPOT_LIGHTS = 2;                                                      

struct DirectionalLight                                                             
{   
    vec3 Color;
    float AmbientIntensity;
    float DiffuseIntensity;
};                                                                                  

// IN
in float vClipSpacePosZ;
in vec2 vTexcoords;
in vec3 vNormalWS;
in vec3 vViewdirWS;
in vec3 vPositionWS;
in vec4 vPositionLS[NUM_CASCADES];

// OUT
out vec4 FragColor;

uniform float uHeightScale = 0.1;
uniform vec3 uEyePositionWS;
uniform float uSpecularPower = 5.f;
uniform float uMatSpecularIntensity = 0.2f;
uniform vec3 uLightDirection;
uniform float uCascadeEndClipSpace[NUM_CASCADES];
uniform DirectionalLight uDirectionalLight;                                                 

uniform sampler2D uTexShadowmap[NUM_CASCADES];
uniform sampler2D uTexDiffuseMapSamp;
uniform sampler2D uTexNormalMapSamp;
uniform sampler2D uTexDepthMapSamp;

vec3 CalcDirectionalLight(DirectionalLight light, vec3 cameradireciton, vec3 SunDirection, vec3 Normal, float ShadowFactor)
{
    vec3 AmbientColor = vec3(light.Color * light.AmbientIntensity);
    float DiffuseFactor = dot(Normal, -SunDirection);

    vec3 DiffuseColor = vec3(0, 0, 0);
    vec3 SpecularColor = vec3(0, 0, 0);

    if (DiffuseFactor > 0) {
        DiffuseColor = vec3(light.Color * light.DiffuseIntensity * DiffuseFactor);

        vec3 LightReflect = normalize(reflect(SunDirection, Normal));
        vec3 HalfwayDir = normalize(cameradireciton - SunDirection);  
        float SpecularFactor = dot(HalfwayDir, Normal);                                      
        if (SpecularFactor > 0) {                                                           
            SpecularFactor = pow(SpecularFactor, uSpecularPower);                               
            SpecularColor = vec3(light.Color) * uMatSpecularIntensity * SpecularFactor;                         
        }                                                                                   
    }
    return (AmbientColor + ShadowFactor * (DiffuseColor + SpecularColor));
}

// method used in Ray-MMD
mat3x3 CalcTBN(vec3 normal)
{
    // get edge vectors of the pixel triangle
    vec3 dp1 = dFdx(vViewdirWS);
    vec3 dp2 = dFdy(vViewdirWS);
    vec3 duv1 = dFdx(vec3(vTexcoords, 0.0));
    vec3 duv2 = dFdy(vec3(vTexcoords, 0.0));

#if 1
    // solve the linear system
    vec3 dp2perp = cross(dp2, normal);
    vec3 dp1perp = cross(normal, dp1);
    mat3x3 M = mat3x3(dp1, dp2, normal);
    mat2x3 I = mat2x3(dp2perp, dp1perp);
    vec3 T = I*vec2(duv1.x, duv2.x);
    vec3 B = I*vec2(duv1.y, duv2.y);

    // construct a scale-invariant frame
    mat3x3 tbnTransform;
    float scaleT = -1.0 / (dot(T, T) + 1e-6);
    float scaleB = -1.0 / (dot(B, B) + 1e-6);

    tbnTransform[0] = normalize(T * scaleT);
    tbnTransform[1] = normalize(B * scaleB);
    tbnTransform[2] = normal;

    return tbnTransform;
#else
    float f = 1.0 / (duv1.s * duv2.t - duv2.s * duv1.t);
    vec3 n = normal;
    vec3 t = (duv2.t * dp1 - duv1.t * dp2) * f;
    t = normalize(t - n * dot(n, t));
    vec3 b = normalize(cross(n, t));
    return mat3(-t, -b, n);
#endif
}

vec2 ParallaxMapping(vec2 texCoords, vec3 viewDir)
{
    // number of depth layers
    const float numLayers = mix(64.0, 8.0, abs(dot(vec3(0.0, 0.0, 1.0), viewDir)));

    // calculate the size of each layer
    float layerDepth = 1.0 / numLayers;
    // depth of current layer
    float currentLayerDepth = 0.0;
    // the amount to shift the texture coordinates per layer (from vector P)
    vec2 P = viewDir.xy * uHeightScale / viewDir.z;
    vec2 deltaTexCoords = P / numLayers;

    vec2 currentTexCoords = texCoords;
    float currentDepthValue = texture2D(uTexDepthMapSamp, currentTexCoords).r;
    while (currentLayerDepth < currentDepthValue)
    {
        // shift texture coordinates along direction of P
        currentTexCoords -= deltaTexCoords;
        currentDepthValue = texture2D(uTexDepthMapSamp, currentTexCoords).r;
        currentLayerDepth += layerDepth;
    }
    return currentTexCoords;
}

void main()
{
    mat3 tbnTransform = transpose(CalcTBN(normalize(vNormalWS)));
    vec3 viewdirTS = normalize(tbnTransform*normalize(vViewdirWS));
    vec2 texCoords = ParallaxMapping(vTexcoords, viewdirTS);
    // can't be used in repeated texture pattern (texcoord range over 1.0)
    // if (texCoords.x > 1.0 || texCoords.y > 1.0 || texCoords.x < 0.0 || texCoords.y < 0.0) discard;
    vec3 normalTS = texture2D(uTexNormalMapSamp, texCoords).rgb * 2.0 - 1.0;
    vec3 normal = normalize(transpose(tbnTransform)*normalTS);
    vec3 lightdirectionTS = normalize(tbnTransform*uLightDirection);
    vec3 positionTS = tbnTransform*vPositionWS;
    vec3 cameraPositionTS = tbnTransform*uEyePositionWS;
    vec3 cameradirectionTS = normalize(cameraPositionTS - positionTS);

    vec4 CascadeIndicator = vec4(0.3, 0.0, 0.3, 0.0);
    float ShadowFactor = CalcShadowCascaded(vClipSpacePosZ, uCascadeEndClipSpace, uTexShadowmap, vPositionLS, normalTS, lightdirectionTS, CascadeIndicator);

#if 0
    vec3 sumLight = CalcDirectionalLight(uDirectionalLight, cameradirectionTS, lightdirectionTS, normalTS, ShadowFactor);
#else
    vec3 sumLight = CalcDirectionalLight(uDirectionalLight, normalize(uEyePositionWS - vPositionWS), normalize(uLightDirection), normal, ShadowFactor);
#endif

    vec3 SampledColor = texture2D(uTexDiffuseMapSamp, texCoords).rgb;
    FragColor = vec4(vec3(sumLight)*SampledColor, 1.0); // + CascadeIndicator;
}