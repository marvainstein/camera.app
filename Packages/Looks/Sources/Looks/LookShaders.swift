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
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    // Triángulo que cubre toda la pantalla, sin vertex buffer.
    vertex VOut look_vertex(uint vid [[vertex_id]], constant LookUniforms &u [[buffer(0)]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y) * u.uvTransform.xy + u.uvTransform.zw;
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

    fragment float4 look_fragment(VOut in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  texture3d<float> lut [[texture(1)]],
                                  sampler sourceSampler [[sampler(0)]],
                                  sampler lutSampler [[sampler(1)]],
                                  constant LookUniforms &u [[buffer(0)]]) {
        float3 rgb = saturate(source.sample(sourceSampler, in.uv).rgb);

        if (u.hasLUT != 0 && u.intensity > 0.0) {
            // Centro de texel: el nodo i del LUT vive en (i + 0.5) / N.
            float3 coord = rgb * ((u.lutSize - 1.0) / u.lutSize) + 0.5 / u.lutSize;
            float3 graded = lut.sample(lutSampler, coord).rgb;
            rgb = mix(rgb, graded, u.intensity);
        }

        if (u.grainAmount > 0.0) {
            uint2 cell = uint2(in.position.xy / max(u.grainCell, 1.0));
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            // Más grano en medios tonos que en negros y blancos.
            float response = 0.3 + 0.7 * (4.0 * luma * (1.0 - luma));
            rgb += gaussian(cell, u.seed) * u.grainAmount * 0.1 * response;
        }

        return float4(saturate(rgb), 1.0);
    }
    """
}
