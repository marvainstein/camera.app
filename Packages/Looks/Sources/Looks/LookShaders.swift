/// Fuente Metal del pipeline de Looks. Se compila en runtime (`makeLibrary(source:)`) para que el
/// paquete funcione igual con `swift test` en macOS y con Xcode en iOS, sin depender de que SwiftPM
/// compile `.metal`.
enum LookShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Debe coincidir con `LookUniforms` en LookRenderer.swift.
    struct LookUniforms {
        float4 uvTransform;   // xy = escala, zw = desplazamiento de las coordenadas de la fuente
        float intensity;      // mezcla entre la entrada (0) y el LUT (1)
        float grainAmount;    // desvío estándar del grano (en unidades 0…1)
        float grainCell;      // tamaño de la celda de grano en píxeles de salida
        uint seed;
        float lutSize;
        uint hasLUT;
        float sharpness;      // nitidez −1…1
        float clarity;        // claridad −1…1 (usa la textura reducida)
        float vignette;       // viñeteo −1…1
        uint hasBlur;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;            // coordenadas en la fuente
        float2 frame;         // 0…1 sobre el cuadro de salida
    };

    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

    // Triángulo que cubre toda la pantalla, sin vertex buffer.
    vertex VOut look_vertex(uint vid [[vertex_id]], constant LookUniforms &u [[buffer(0)]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.frame = float2(p.x, 1.0 - p.y);
        o.uv = o.frame * u.uvTransform.xy + u.uvTransform.zw;
        return o;
    }

    // Hash entero (PCG) → uniforme en (0, 1].
    static uint pcg(uint v) {
        uint state = v * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }

    static float uniform01(uint v) {
        return (float(pcg(v)) + 1.0) / 4294967296.0;
    }

    // Ruido gaussiano N(0, 1) por celda (Box-Muller).
    static float gaussian(uint2 cell, uint seed) {
        uint h = pcg(cell.x + pcg(cell.y + pcg(seed)));
        float u1 = uniform01(h);
        float u2 = uniform01(h ^ 0x9E3779B9u);
        return sqrt(-2.0 * log(u1)) * cos(6.28318530718 * u2);
    }

    // Promedio de 8×8 muestras bilineales repartidas en el área de la fuente que cubre este píxel
    // (base de la claridad).
    fragment float4 look_downsample(VOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    sampler sourceSampler [[sampler(0)]]) {
        float2 footprint = abs(float2(dfdx(in.uv.x), dfdy(in.uv.y)));
        float3 sum = float3(0.0);
        for (int j = 0; j < 8; j++) {
            for (int i = 0; i < 8; i++) {
                float2 offset = ((float2(i, j) + 0.5) / 8.0 - 0.5) * footprint;
                sum += saturate(source.sample(sourceSampler, in.uv + offset).rgb);
            }
        }
        return float4(sum / 64.0, 1.0);
    }

    fragment float4 look_fragment(VOut in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  texture3d<float> lut [[texture(1)]],
                                  texture2d<float> blurred [[texture(2)]],
                                  sampler sourceSampler [[sampler(0)]],
                                  sampler lutSampler [[sampler(1)]],
                                  constant LookUniforms &u [[buffer(0)]]) {
        float3 rgb = saturate(source.sample(sourceSampler, in.uv).rgb);

        // Nitidez: realza (o suaviza) la diferencia de luminancia con los 4 vecinos de la fuente.
        if (u.sharpness != 0.0) {
            float2 texel = 1.0 / float2(source.get_width(), source.get_height());
            float3 around = (source.sample(sourceSampler, in.uv + float2(texel.x, 0.0)).rgb
                           + source.sample(sourceSampler, in.uv - float2(texel.x, 0.0)).rgb
                           + source.sample(sourceSampler, in.uv + float2(0.0, texel.y)).rgb
                           + source.sample(sourceSampler, in.uv - float2(0.0, texel.y)).rgb) * 0.25;
            float detail = dot(rgb - saturate(around), kLuma);
            rgb = saturate(rgb + detail * (u.sharpness > 0.0 ? 1.5 * u.sharpness : u.sharpness));
        }

        // Claridad: contraste local contra la fuente reducida, sobre todo en medios tonos.
        if (u.clarity != 0.0 && u.hasBlur != 0) {
            float2 texel = 0.5 / float2(blurred.get_width(), blurred.get_height());
            float3 local = (blurred.sample(sourceSampler, in.uv + texel).rgb
                          + blurred.sample(sourceSampler, in.uv - texel).rgb
                          + blurred.sample(sourceSampler, in.uv + float2(texel.x, -texel.y)).rgb
                          + blurred.sample(sourceSampler, in.uv + float2(-texel.x, texel.y)).rgb) * 0.25;
            float luma = dot(rgb, kLuma);
            float midtones = 4.0 * luma * (1.0 - luma);
            rgb = saturate(rgb + (luma - dot(local, kLuma)) * u.clarity * midtones);
        }

        if (u.hasLUT != 0 && u.intensity > 0.0) {
            // Centro de texel: el nodo i del LUT vive en (i + 0.5) / N.
            float3 coord = rgb * ((u.lutSize - 1.0) / u.lutSize) + 0.5 / u.lutSize;
            float3 graded = lut.sample(lutSampler, coord).rgb;
            rgb = mix(rgb, graded, u.intensity);
        }

        // Viñeteo: 0 en el centro, máximo en las esquinas del cuadro de salida.
        if (u.vignette != 0.0) {
            float r = length(in.frame - 0.5) * 1.41421356;
            rgb = saturate(rgb * (1.0 - 0.5 * u.vignette * smoothstep(0.25, 1.0, r)));
        }

        if (u.grainAmount > 0.0) {
            uint2 cell = uint2(in.position.xy / max(u.grainCell, 1.0));
            float luma = dot(rgb, kLuma);
            // Más grano en medios tonos que en negros y blancos.
            float response = 0.3 + 0.7 * (4.0 * luma * (1.0 - luma));
            rgb += gaussian(cell, u.seed) * u.grainAmount * 0.1 * response;
        }

        return float4(saturate(rgb), 1.0);
    }
    """
}
