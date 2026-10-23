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
    static bool bokeh_inside_aperture(float2 d, constant BokehUniforms &u) {
        float sector = 2.0 * M_PI_F / u.blades;
        float angle = atan2(d.y, d.x) + M_PI_F;
        float offset = angle - sector * floor(angle / sector) - sector * 0.5;
        float edge = cos(sector * 0.5) / cos(offset);
        return length(d) <= mix(edge, 1.0, u.roundness);
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
        const int count = 160;
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
    """
}
