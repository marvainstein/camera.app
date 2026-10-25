/// Shaders del bokeh. Se compilan junto con `LookShaders.source` (usan `VOut`, `look_vertex` y
/// `kLuma` de ahí). Forma del bokeh propia y sintética: nada medido de otras apps.
enum BokehShaders {
    static let source = """

    // Debe coincidir con `BokehUniforms` en Bokeh.swift.
    struct BokehUniforms {
        float2 sourceSize;    // píxeles de la foto
        float2 workSize;      // píxeles de la versión reducida
        float radius;         // radio de los discos, en píxeles reducidos
        float blades;         // hojas del diafragma
        float roundness;      // 1 = disco redondo, 0 = polígono de las hojas
        float catEye;         // recorte del disco hacia las esquinas (ojo de gato)
        float highlightGain;  // peso extra de las luces fuertes
        uint sampleCount;     // puntos de la espiral que llena el disco
        float4 matteX;        // coordenadas del matte (derecho) desde las de la foto guardada
        float4 matteY;
    };

    static float bokeh_matte(texture2d<float> matte, sampler s, float2 uv, constant BokehUniforms &u) {
        float3 p = float3(uv, 1.0);
        return matte.sample(s, float2(dot(u.matteX.xyz, p), dot(u.matteY.xyz, p))).r;
    }

    // El desenfoque se mezcla en luz lineal, como en una lente; la foto viene codificada (sRGB o P3,
    // la misma curva).
    static float3 bokeh_linear(float3 c) { return pow(max(c, 0.0), 2.2); }
    static float3 bokeh_encoded(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }

    // ¿El punto `d` del disco unidad pasa por el diafragma? Polígono regular de `blades` lados
    // inscripto en el círculo, más redondo cuanto más abierto.
    static bool aperture_contains(float2 d, float blades, float roundness) {
        float sector = 2.0 * M_PI_F / blades;
        float angle = atan2(d.y, d.x) + M_PI_F;
        float offset = angle - sector * floor(angle / sector) - sector * 0.5;
        float edge = cos(sector * 0.5) / cos(offset);
        return length(d) <= mix(edge, 1.0, roundness);
    }

    static bool bokeh_inside_aperture(float2 d, constant BokehUniforms &u) {
        return aperture_contains(d, u.blades, u.roundness);
    }

    // 1. Versión reducida, en luz lineal y sin la persona (para que no se "derrame" sobre el fondo).
    //    rgb premultiplicado por el peso, a = peso: fondo × (1 + más para las luces fuertes).
    fragment float4 bokeh_prepare(VOut in [[stage_in]],
                                  constant BokehUniforms &u [[buffer(0)]],
                                  texture2d<float> source [[texture(0)]],
                                  texture2d<float> matte [[texture(1)]],
                                  sampler s [[sampler(0)]]) {
        float2 footprint = 1.0 / u.workSize;
        float3 color = float3(0.0);
        float weight = 0.0;
        for (int j = 0; j < 4; j++) {
            for (int i = 0; i < 4; i++) {
                float2 offset = (float2(i, j) + 0.5) / 4.0 - 0.5;
                float3 c = bokeh_linear(source.sample(s, in.uv + offset * footprint).rgb);
                float w = 1.0 + u.highlightGain * smoothstep(0.55, 1.0, dot(c, kLuma));
                color += c * w;
                weight += w;
            }
        }
        float background = 1.0 - bokeh_matte(matte, s, in.uv, u);
        return float4(color, weight) * (background / 16.0);
    }

    // 2. Desenfoque con la forma de la apertura: promedio ponderado sobre una espiral de puntos
    //    que llena el disco. Hacia las esquinas, el disco se corta con otro corrido hacia afuera
    //    (ojo de gato). rgb = color del fondo, a = cuánto fondo había alrededor.
    fragment float4 bokeh_gather(VOut in [[stage_in]],
                                 constant BokehUniforms &u [[buffer(0)]],
                                 texture2d<float> prepared [[texture(0)]],
                                 sampler s [[sampler(0)]]) {
        const int count = int(u.sampleCount);
        float2 fromCenter = (in.uv - 0.5) * u.workSize / (0.5 * length(u.workSize));
        float2 eye = fromCenter * u.catEye;
        float4 sum = float4(0.0);
        int used = 0;
        for (int k = 0; k < count; k++) {
            float r = sqrt((float(k) + 0.5) / float(count));
            float a = float(k) * 2.39996323;
            float2 d = r * float2(cos(a), sin(a));
            if (!bokeh_inside_aperture(d, u) || length(d - eye) > 1.0) {
                continue;
            }
            sum += prepared.sample(s, in.uv + d * u.radius / u.workSize);
            used++;
        }
        if (sum.a <= 1e-5) {
            return float4(0.0);
        }
        return float4(sum.rgb / sum.a, sum.a / float(max(used, 1)));
    }

    // 3. La persona nítida sobre el fondo desenfocado. Donde no había fondo alrededor (adentro de la
    //    persona), queda la foto.
    fragment float4 bokeh_composite(VOut in [[stage_in]],
                                    constant BokehUniforms &u [[buffer(0)]],
                                    texture2d<float> source [[texture(0)]],
                                    texture2d<float> blurred [[texture(1)]],
                                    texture2d<float> matte [[texture(2)]],
                                    sampler s [[sampler(0)]]) {
        float3 photo = source.sample(s, in.uv).rgb;
        float4 b = blurred.sample(s, in.uv);
        float3 background = b.a > 1e-4 ? clamp(bokeh_encoded(b.rgb), 0.0, 1.0) : photo;
        float person = bokeh_matte(matte, s, in.uv, u);
        return float4(mix(background, photo, person), 1.0);
    }

    // ---- Bokeh por profundidad ----

    // Debe coincidir con `DepthUniforms` en DepthBokeh.swift.
    struct DepthUniforms {
        float2 workSize;            // píxeles de la versión reducida
        float maxRadius;            // desenfoque máximo, en píxeles reducidos
        float radiusPerDisparity;   // píxeles reducidos de desenfoque por 1/m de diferencia con el foco
        float focusDisparity;       // disparidad del plano nítido
        float blades;
        float roundness;
        float catEye;
        float highlightGain;
        uint sampleCount;
        uint hasMatte;              // 1: la persona está en foco y su recorte afina los bordes
        float fullScale;            // píxeles reducidos por píxel de la foto
    };

    // 1. Versión reducida en luz lineal. rgb premultiplicado por el peso de las luces, a = peso.
    //    En un borde (un píxel reducido con algo cerca y algo lejos), se queda con lo de atrás: si no,
    //    el color de lo que está adelante se mezclaría con el fondo y haría un halo al desenfocarlo.
    fragment float4 depth_prepare(VOut in [[stage_in]],
                                  constant DepthUniforms &u [[buffer(0)]],
                                  texture2d<float> source [[texture(0)]],
                                  texture2d<float> depth [[texture(1)]],
                                  sampler s [[sampler(0)]]) {
        float2 footprint = 1.0 / u.workSize;
        float3 colors[16];
        float disparities[16];
        float farthest = 1e9;
        for (int k = 0; k < 16; k++) {
            float2 uv = in.uv + ((float2(k % 4, k / 4) + 0.5) / 4.0 - 0.5) * footprint;
            colors[k] = bokeh_linear(source.sample(s, uv).rgb);
            disparities[k] = depth.sample(s, uv).r;
            farthest = min(farthest, disparities[k]);
        }
        float3 color = float3(0.0);
        float weight = 0.0;
        for (int k = 0; k < 16; k++) {
            // Entra lo que tiene casi el mismo desenfoque que lo de más atrás (menos de un píxel reducido).
            float keep = saturate(1.5 - (disparities[k] - farthest) * u.radiusPerDisparity);
            float w = keep * (1.0 + u.highlightGain * smoothstep(0.55, 1.0, dot(colors[k], kLuma)));
            color += colors[k] * w;
            weight += w;
        }
        return float4(color, weight) / 16.0;
    }

    // 2. Desenfoque de cada punto (con signo: positivo = delante del foco). La profundidad viene en
    //    baja resolución: se promedia con los vecinos de color parecido para que siga los bordes de la
    //    imagen. Con la persona en foco, su recorte la deja nítida.
    fragment float4 depth_coc(VOut in [[stage_in]],
                              constant DepthUniforms &u [[buffer(0)]],
                              texture2d<float> depth [[texture(0)]],
                              texture2d<float> matte [[texture(1)]],
                              texture2d<float> prepared [[texture(2)]],
                              sampler s [[sampler(0)]]) {
        float2 texel = 1.0 / u.workSize;
        float4 pc = prepared.sample(s, in.uv);
        float lc = sqrt(dot(pc.rgb / max(pc.a, 1e-5), kLuma));
        float sum = 0.0;
        float weights = 0.0;
        for (int j = -2; j <= 2; j++) {
            for (int i = -2; i <= 2; i++) {
                float2 uv = in.uv + float2(i, j) * texel * 2.0;
                float4 p = prepared.sample(s, uv);
                float l = sqrt(dot(p.rgb / max(p.a, 1e-5), kLuma));
                float w = exp(-(l - lc) * (l - lc) / 0.01) * exp(-float(i * i + j * j) / 4.0);
                sum += depth.sample(s, uv).r * w;
                weights += w;
            }
        }
        float d = sum / max(weights, 1e-5);
        if (u.hasMatte != 0) {
            d = mix(d, u.focusDisparity, matte.sample(s, in.uv).r);
        }
        float coc = clamp((d - u.focusDisparity) * u.radiusPerDisparity, -u.maxRadius, u.maxRadius);
        return float4(coc, 0.0, 0.0, 1.0);
    }

    // 3. Cada punto se reparte en un disco de su propio tamaño, con la forma de la apertura: acá se
    //    junta, para cada píxel, lo que le llega de los discos vecinos que lo cubren (cada uno con su
    //    luz repartida en su área). Lo que está más lejos no tapa lo que está más cerca y más nítido.
    fragment float4 depth_gather(VOut in [[stage_in]],
                                 constant DepthUniforms &u [[buffer(0)]],
                                 texture2d<float> prepared [[texture(0)]],
                                 texture2d<float> coc [[texture(1)]],
                                 sampler s [[sampler(0)]]) {
        const int count = int(u.sampleCount);
        float center = coc.sample(s, in.uv).r;
        float centerSize = abs(center);
        float2 fromCenter = (in.uv - 0.5) * u.workSize / (0.5 * length(u.workSize));
        float2 eye = fromCenter * u.catEye;
        float minArea = max(u.maxRadius * u.maxRadius / float(count), 1.0);
        float4 sum = float4(0.0);
        for (int k = 0; k < count; k++) {
            float r = sqrt((float(k) + 0.5) / float(count));
            float a = float(k) * 2.39996323;
            float2 offset = r * u.maxRadius * float2(cos(a), sin(a));
            float2 uv = in.uv + offset / u.workSize;
            float sampleCoc = coc.sample(s, uv).r;
            float size = abs(sampleCoc);
            if (sampleCoc < center) {
                size = min(size, centerSize * 2.0);
            }
            float cover = saturate(size - length(offset) + 0.5);
            if (cover <= 0.0) {
                continue;
            }
            if (size > 0.5) {
                float2 q = -offset / size;
                if (!aperture_contains(q, u.blades, u.roundness) || length(q - eye) > 1.0) {
                    continue;
                }
            }
            sum += prepared.sample(s, uv) * (cover / max(size * size, minArea));
        }
        if (sum.a <= 1e-6) {
            float4 own = prepared.sample(s, in.uv);
            return float4(own.rgb / max(own.a, 1e-5), 1.0);
        }
        return float4(sum.rgb / sum.a, 1.0);
    }

    // 4. Lo que está en foco, de la foto a resolución completa; lo desenfocado, de la versión reducida.
    fragment float4 depth_composite(VOut in [[stage_in]],
                                    constant DepthUniforms &u [[buffer(0)]],
                                    texture2d<float> source [[texture(0)]],
                                    texture2d<float> blurred [[texture(1)]],
                                    texture2d<float> coc [[texture(2)]],
                                    sampler s [[sampler(0)]]) {
        float3 photo = source.sample(s, in.uv).rgb;
        float3 b = clamp(bokeh_encoded(blurred.sample(s, in.uv).rgb), 0.0, 1.0);
        float size = abs(coc.sample(s, in.uv).r) / max(u.fullScale, 1e-5);
        return float4(mix(photo, b, smoothstep(0.75, 2.0, size)), 1.0);
    }
    """
}
