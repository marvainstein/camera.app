import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Looks

/// Imagen de prueba que recorre los 256 niveles de cada canal con combinaciones variadas.
private func testPattern(width: Int = 256, height: Int = 64) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8(x)
            pixels[i + 1] = UInt8((x * 7 + y * 13) % 256)
            pixels[i + 2] = UInt8((255 - x + y * 29) % 256)
        }
    }
    return pixels
}

private func render(_ renderer: LookRenderer, lut: LUT3D?, parameters: LookParameters,
                    pixels: [UInt8] = testPattern(), width: Int = 256, height: Int = 64,
                    format: MTLPixelFormat = .rgba8Unorm) throws -> [UInt8] {
    let source = try renderer.makeTexture(rgba8: pixels, width: width, height: height)
    let target = try renderer.makeRenderTarget(width: width, height: height, pixelFormat: format)
    let lutTexture = try lut.map { try renderer.makeLUTTexture($0) }
    let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
    try renderer.encode(commandBuffer: commandBuffer, source: source, lut: lutTexture,
                        destination: target, parameters: parameters)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return try renderer.readBytes(target)
}

private func maxChannelDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).enumerated()
        .filter { $0.offset % 4 != 3 }
        .map { abs(Int($0.element.0) - Int($0.element.1)) }
        .max() ?? 0
}

@Suite struct LUTFileTests {
    @Test func encodeDecodeRoundTrip() throws {
        let lut = LUT3D(size: 8) { SIMD3($0.z, $0.x, $0.y) }
        #expect(try LUT3D(data: lut.encoded()) == lut)
    }

    @Test func rejectsForeignFiles() {
        #expect(throws: LUT3D.Error.badHeader) { try LUT3D(data: Data("no es un LUT".utf8)) }
    }

    @Test func rejectsTruncatedFiles() throws {
        let data = LUT3D.identity(size: 4).encoded().dropLast(8)
        #expect(throws: LUT3D.Error.self) { try LUT3D(data: Data(data)) }
    }

    @Test func bundledLooksLoad() throws {
        let looks = try LookCatalog.bundled()
        #expect(Set(["identidad", "bn-neutro", "calido"]).isSubset(of: looks.map(\.id)))
        for look in looks {
            #expect(try LookCatalog.lut(for: look, cacheDirectory: nil).size == 64)
        }
    }

    @Test func bundledIdentityMatchesGeneratedIdentity() throws {
        let identity = try #require(try LookCatalog.bundled().first { $0.id == "identidad" })
        #expect(try LookCatalog.lut(for: identity) == LUT3D.identity(size: 64))
    }
}

/// Referencias 17³ que escribe `scripts/make_luts.py export-reference` con `film_look()`.
private func pythonReference(_ id: String) throws -> LUT3D {
    let url = try #require(Bundle.module.url(forResource: id, withExtension: "lut"))
    return try LUT3D(contentsOf: url)
}

private let recipeLookIDs = ["dorado-200", "retrato-400", "ambar-800", "negativo-diario", "diapositiva",
                             "plata-400", "cine-verde", "estandar", "clasico", "contemporaneo", "vivido", "puro",
                             "laton", "azul", "verde-azulado", "cine", "cine-suave", "blanqueo", "documental",
                             "retrato-calido", "bn-alto-contraste", "plata-suave", "selenio", "sepia", "centenario",
                             "bn-filtro-amarillo", "bn-filtro-naranja", "bn-filtro-rojo", "bn-filtro-verde",
                             "bn-filtro-azul"]

@Suite struct FilmRecipeTests {
    @Test(arguments: recipeLookIDs)
    func swiftMatchesPythonReference(id: String) throws {
        let look = try #require(try LookCatalog.bundled().first { $0.id == id })
        let recipe = try #require(look.recipe)
        let reference = try pythonReference(id)
        let generated = recipe.makeLUT(size: reference.size)
        let expected = reference.floatTexels, actual = generated.floatTexels
        var worst: Float = 0
        for i in expected.indices {
            worst = max(worst, abs(expected[i] - actual[i]))
        }
        #expect(worst <= 1 / 1024)
    }

    @Test func everyRecipeHasAReference() throws {
        let withRecipe = try LookCatalog.bundled().filter { $0.recipe != nil }.map(\.id)
        #expect(withRecipe == recipeLookIDs)
        for id in withRecipe {
            #expect(try pythonReference(id).size == 17)
        }
    }

    @Test func optionalFieldsDefaultToZero() throws {
        let json = """
        {"calidez": 1, "altas_luces": 0.1, "contraste": 0.2, "negros": 0.03, "blancos": 0.97,
         "verdes_oliva": 4, "verdes_apagados": 0.1, "azules_apagados": 0.1, "rojos_amarillos": 0,
         "saturacion": 1, "sombras_frias": 1, "luces_amarillas": 1}
        """
        let recipe = try JSONDecoder().decode(FilmRecipe.self, from: Data(json.utf8))
        #expect(recipe.tinte == 0 && recipe.brillo == 0 && recipe.mono == 0)
        let roundTrip = try JSONDecoder().decode(FilmRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(roundTrip == recipe)
    }

    @Test func colorFilterChangesOnlyBlackAndWhite() {
        var mono = FilmRecipe.neutral
        mono.mono = 1
        var red = mono
        red.filtro = 1
        red.filtroTono = 0
        // Cielo azul: con filtro rojo sale más oscuro que sin filtro.
        let sky = (0.35, 0.55, 0.85)
        #expect(red.apply(sky.0, sky.1, sky.2).0 < mono.apply(sky.0, sky.1, sky.2).0 - 0.1)
        // Un rojo sale más claro.
        #expect(red.apply(0.8, 0.2, 0.15).0 > mono.apply(0.8, 0.2, 0.15).0 + 0.1)
        // Sigue siendo neutro y, en color, el filtro no hace nada.
        let out = red.apply(0.3, 0.6, 0.2)
        #expect(out.0 == out.1 && out.1 == out.2)
        var color = FilmRecipe.neutral
        color.filtro = 1
        #expect(color.apply(0.3, 0.6, 0.2) == FilmRecipe.neutral.apply(0.3, 0.6, 0.2))
    }

    @Test func splitToningTintsWithoutChangingNeutralRecipes() {
        var sepia = FilmRecipe.neutral
        sepia.viradoSombras = 1.5
        sepia.viradoSombrasTono = 30
        let toned = sepia.apply(0.4, 0.4, 0.4)
        #expect(toned.0 > toned.1 && toned.1 > toned.2)  // marrón: R > G > B
        var off = sepia
        off.viradoSombras = 0
        #expect(off.apply(0.4, 0.4, 0.4) == FilmRecipe.neutral.apply(0.4, 0.4, 0.4))
    }

    @Test func pythonModuloAndColorsys() {
        #expect(FilmMath.pyMod(-30, 360) == 330)
        #expect(FilmMath.pyMod(370, 360) == 10)
        #expect(FilmMath.pyMod(-1e-20, 360) == 360)  // igual que Python
        #expect(FilmMath.pyMod(-0.5, 1).sign == .plus)
        let (h, s, v) = FilmMath.rgbToHSV(0.2, 0.4, 0.8)
        let (r, g, b) = FilmMath.hsvToRGB(h, s, v)
        #expect(abs(r - 0.2) < 1e-12 && abs(g - 0.4) < 1e-12 && abs(b - 0.8) < 1e-12)
        #expect(FilmMath.rgbToHSV(0.5, 0.5, 0.5) == (0, 0, 0.5))
    }

    @Test func stableHashDependsOnlyOnValues() throws {
        let recipe = try #require(try LookCatalog.bundled().first { $0.id == "dorado-200" }?.recipe)
        var other = recipe
        #expect(other.stableHash == recipe.stableHash)
        other.calidez += 0.01
        #expect(other.stableHash != recipe.stableHash)
        #expect(recipe.stableHash.count == 16)
    }

    @Test func catalogCachesGeneratedLUTOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LooksTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let look = try #require(try LookCatalog.bundled().first { $0.id == "cine-verde" })
        let lut = try LookCatalog.lut(for: look, cacheDirectory: directory)
        let key = LookCatalog.cacheKey(id: look.id, recipe: try #require(look.recipe))
        let file = directory.appendingPathComponent(key + ".lut")
        #expect(try LUT3D(contentsOf: file) == lut)
        #expect(lut.size == 64)
    }

    @Test func lookWithoutRecipeOrFileFails() {
        #expect(throws: LookCatalog.Error.noLUT("vacio")) {
            try LookCatalog.lut(for: Look(id: "vacio", name: "Vacío"))
        }
    }
}

@Suite struct RecipeEditingTests {
    @Test func neutralRecipeIsIdentity() {
        let lut = FilmRecipe.neutral.makeLUT(size: 17)
        let identity = LUT3D.identity(size: 17).floatTexels
        let values = lut.floatTexels
        var worst: Float = 0
        for i in values.indices {
            worst = max(worst, abs(values[i] - identity[i]))
        }
        #expect(worst <= 1 / 2048)
    }

    @Test func parametersCoverEveryRecipeKey() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FilmRecipe.neutral)) as? [String: Any]
        let keys = Set(try #require(json).keys)
        #expect(Set(FilmRecipe.parameters.map(\.id)).union(["mono"]) == keys)
        #expect(Set(FilmRecipe.parameters.map(\.id)).count == FilmRecipe.parameters.count)
    }

    @Test func bundledRecipesFitTheEditorRanges() throws {
        for look in try LookCatalog.bundled() {
            guard let recipe = look.recipe else { continue }
            #expect(recipe.clamped == recipe, "\(look.id) se sale de los rangos del editor")
            for parameter in FilmRecipe.parameters {
                #expect(parameter.range.contains(FilmRecipe.neutral[keyPath: parameter.keyPath]))
            }
        }
    }

    @Test func clampedKeepsRecipesInRange() {
        var recipe = FilmRecipe.neutral
        recipe.contraste = 50
        recipe.calidez = -.infinity
        recipe.mono = 0.3
        let clamped = recipe.clamped
        #expect(clamped.contraste == 0.6)
        #expect(clamped.calidez == 0)
        #expect(clamped.mono == 1)
    }

    @Test func ricohLooksCarryTheirEffects() throws {
        let looks = try LookCatalog.bundled()
        let plata = try #require(looks.first { $0.id == "plata-400" })
        #expect(plata.effects == LookEffects(claridad: 0.5, vineteo: 0.25))
        let cineLook = try #require(looks.first { $0.id == "cine" })
        #expect(cineLook.effects?.halation == 0.45 && cineLook.effects?.bloom == 0.2)
        let cine = try #require(looks.first { $0.id == "cine-verde" })
        #expect(cine.effects?.nitidez == -0.5)
        #expect(looks.first { $0.id == "dorado-200" }?.effects == nil)
    }

    @Test func lutKeyFollowsTheRecipe() throws {
        var recipe = FilmRecipe.neutral
        let a = Look(id: "propia-1", name: "A", recipe: recipe)
        recipe.calidez = 0.5
        let b = Look(id: "propia-1", name: "A", recipe: recipe)
        #expect(a.lutKey != b.lutKey)
        #expect(Look(id: "calido", name: "Cálido", lut: "calido.lut").lutKey == "calido")
    }
}

@Suite struct UserLookTests {
    private func temporaryStore() -> UserLookStore {
        UserLookStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("LooksTests-\(UUID().uuidString)/user-looks.json"))
    }

    @Test func storeRoundTrip() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        #expect(try store.load().isEmpty)
        var recipe = FilmRecipe.neutral
        recipe.calidez = 0.7
        let looks = [Look(id: UserLookStore.newID(), name: "Mía", recipe: recipe, grain: 0.25,
                          effects: LookEffects(claridad: 0.3))]
        try store.save(looks)
        #expect(try store.load() == looks)
        try store.save([])
        #expect(try store.load().isEmpty)
    }

    @Test func newIDsDoNotCollideWithTheCatalog() throws {
        let bundled = Set(try LookCatalog.bundled().map(\.id))
        let id = UserLookStore.newID()
        #expect(id.hasPrefix("propia-") && !bundled.contains(id))
        #expect(UserLookStore.newID() != id)
    }

    @Test func shareRoundTrip() throws {
        let look = try #require(try LookCatalog.bundled().first { $0.id == "plata-400" })
        let text = try LookShare.text(for: look)
        let imported = try LookShare.look(from: "Probá esta:\n\(text)\n¡saludos!", id: "propia-x")
        #expect(imported.id == "propia-x")
        #expect(imported.name == look.name)
        #expect(imported.recipe == look.recipe)
        #expect(imported.grain == look.grain)
        #expect(imported.effects == look.effects)
    }

    @Test func importsALooksJSONEntry() throws {
        let json = """
        {"id": "x", "name": "  Desde el catálogo ", "recipe": {"calidez": 0.5, "altas_luces": 0.1,
         "contraste": 9, "negros": 0.03, "blancos": 0.97, "verdes_oliva": 4, "verdes_apagados": 0.1,
         "azules_apagados": 0.1, "rojos_amarillos": 0, "saturacion": 1, "sombras_frias": 1,
         "luces_amarillas": 1}, "grain": 7, "effects": {"vineteo": -3}}
        """
        let look = try LookShare.look(from: json, id: "propia-y")
        #expect(look.name == "Desde el catálogo")
        #expect(look.recipe?.contraste == 0.6)
        #expect(look.grain == 1)
        #expect(look.effects == LookEffects(vineteo: -1))
    }

    @Test func rejectsTextWithoutARecipe() {
        #expect(throws: LookShare.Error.noRecipeFound) { try LookShare.look(from: "hola", id: "x") }
        #expect(throws: LookShare.Error.noRecipeFound) { try LookShare.look(from: "{\"name\": \"x\"}", id: "x") }
        #expect(throws: LookShare.Error.notARecipe) {
            try LookShare.text(for: Look(id: "calido", name: "Cálido", lut: "calido.lut"))
        }
    }
}

/// Algunas VMs de CI no exponen GPU; ahí se saltean los tests que necesitan Metal.
private let hasMetal = MTLCreateSystemDefaultDevice() != nil

@Suite(.enabled(if: hasMetal, "No hay dispositivo Metal")) struct LookPipelineTests {
    let renderer: LookRenderer

    init() throws {
        renderer = try LookRenderer()
    }

    @Test func identityLUTLeavesImageUnchanged() throws {
        let input = testPattern()
        let output = try render(renderer, lut: .identity(), parameters: LookParameters(intensity: 1))
        #expect(maxChannelDifference(input, output) == 0)
    }

    @Test func identityLUTIsExactInHalfFloatTarget() throws {
        let input = testPattern()
        let target = try renderer.makeRenderTarget(width: 256, height: 64, pixelFormat: .rgba16Float)
        let source = try renderer.makeTexture(rgba8: input, width: 256, height: 64)
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(commandBuffer: commandBuffer, source: source,
                            lut: renderer.makeLUTTexture(.identity()), destination: target,
                            parameters: LookParameters())
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Leer como RGBA16F vía una copia a 8 bytes/píxel.
        let length = 256 * 64 * 8
        let buffer = try #require(renderer.device.makeBuffer(length: length, options: .storageModeShared))
        let readback = try #require(renderer.commandQueue.makeCommandBuffer())
        let blit = try #require(readback.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: 256, height: 64, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: 256 * 8, destinationBytesPerImage: length)
        blit.endEncoding()
        readback.commit()
        readback.waitUntilCompleted()
        let bits = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt16.self),
                                             count: 256 * 64 * 4))
        let floats = LUT3D.floats(fromHalfBits: bits)
        var worst: Float = 0
        for i in floats.indices where i % 4 != 3 {
            worst = max(worst, abs(floats[i] - Float(input[i]) / 255))
        }
        // Errores de float16 en el LUT + filtrado: muy por debajo de medio nivel de 8 bits.
        #expect(worst < 0.5 / 255)
    }

    @Test func zeroIntensityIgnoresLUT() throws {
        let bw = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == "bn-neutro" }))
        let output = try render(renderer, lut: bw, parameters: LookParameters(intensity: 0))
        #expect(maxChannelDifference(testPattern(), output) == 0)
    }

    @Test func noLUTPassesThrough() throws {
        let output = try render(renderer, lut: nil, parameters: LookParameters())
        #expect(maxChannelDifference(testPattern(), output) == 0)
    }

    @Test func bgraDestinationKeepsChannelOrder() throws {
        let output = try render(renderer, lut: .identity(), parameters: LookParameters(), format: .bgra8Unorm)
        let input = testPattern()
        // En memoria BGRA: el byte 0 es azul.
        #expect(output[0] == input[2] && output[1] == input[1] && output[2] == input[0])
    }

    @Test(arguments: ["bn-neutro", "plata-400"])
    func blackAndWhiteLookIsNeutral(id: String) throws {
        let bw = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == id }), cacheDirectory: nil)
        let output = try render(renderer, lut: bw, parameters: LookParameters())
        for i in stride(from: 0, to: output.count, by: 4) {
            #expect(abs(Int(output[i]) - Int(output[i + 1])) <= 1)
            #expect(abs(Int(output[i + 1]) - Int(output[i + 2])) <= 1)
        }
    }

    @Test func gpuMatchesCPUReference() throws {
        let warm = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == "calido" }))
        let input = testPattern()
        let output = try render(renderer, lut: warm, parameters: LookParameters(intensity: 0.75))
        let table = warm.floatTexels
        var worst = 0
        for i in stride(from: 0, to: input.count, by: 4) {
            let rgb = SIMD3(Float(input[i]), Float(input[i + 1]), Float(input[i + 2])) / 255
            let expected = rgb + (warm.apply(rgb, values: table) - rgb) * 0.75
            for c in 0..<3 {
                worst = max(worst, abs(Int((expected[c] * 255).rounded()) - Int(output[i + c])))
            }
        }
        #expect(worst <= 1)
    }

    @Test func grainIsDeterministicAndKeepsMeanBrightness() throws {
        let gray = [UInt8](repeating: 128, count: 256 * 64 * 4)
        let parameters = LookParameters(grain: 0.5, grainScale: 1, seed: 42)
        let a = try render(renderer, lut: nil, parameters: parameters, pixels: gray)
        let b = try render(renderer, lut: nil, parameters: parameters, pixels: gray)
        let c = try render(renderer, lut: nil, parameters: LookParameters(grain: 0.5, grainScale: 1, seed: 7), pixels: gray)
        #expect(a == b)
        #expect(a != c)
        #expect(maxChannelDifference(gray, a) > 0)

        let red = stride(from: 0, to: a.count, by: 4).map { Double(a[$0]) }
        let mean = red.reduce(0, +) / Double(red.count)
        let std = (red.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(red.count)).squareRoot()
        #expect(abs(mean - 128) < 1)
        // grain 0.5 → σ = 0.05 en medios tonos ≈ 12.75 niveles.
        #expect(abs(std - 12.75) < 2)
    }

    @Test func aspectFillCropsTheLongerSide() {
        let wide = LookRenderer.uvTransform(source: (1920, 1080), destination: (1080, 1080), contentMode: .aspectFill)
        #expect(abs(wide.x - 0.5625) < 1e-6 && wide.y == 1 && abs(wide.z - 0.21875) < 1e-6 && wide.w == 0)
        let tall = LookRenderer.uvTransform(source: (1080, 1920), destination: (1080, 1080), contentMode: .aspectFill)
        #expect(tall.x == 1 && abs(tall.y - 0.5625) < 1e-6)
    }

    @Test func vignetteDarkensCornersOnly() throws {
        let gray = [UInt8](repeating: 160, count: 256 * 64 * 4)
        let output = try render(renderer, lut: nil, parameters: LookParameters(effects: LookEffects(vineteo: 1)),
                                pixels: gray)
        let center = (32 * 256 + 128) * 4, corner = 0
        #expect(abs(Int(output[center]) - 160) <= 1)
        #expect(output[corner] < 100)
        let lighter = try render(renderer, lut: nil, parameters: LookParameters(effects: LookEffects(vineteo: -1)),
                                 pixels: gray)
        #expect(lighter[corner] > 200)
    }

    @Test func sharpnessAndClarityLeaveFlatAreasAlone() throws {
        let gray = [UInt8](repeating: 128, count: 256 * 64 * 4)
        for effects in [LookEffects(nitidez: 1), LookEffects(nitidez: -1), LookEffects(claridad: 1),
                        LookEffects(claridad: -1)] {
            let output = try render(renderer, lut: nil, parameters: LookParameters(effects: effects), pixels: gray)
            #expect(maxChannelDifference(gray, output) <= 1, "\(effects)")
        }
    }

    @Test func sharpnessRaisesEdgeContrast() throws {
        // Borde vertical: mitad izquierda 96, mitad derecha 160.
        var edge = [UInt8](repeating: 255, count: 256 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<256 {
                let i = (y * 256 + x) * 4
                edge[i] = x < 128 ? 96 : 160
                edge[i + 1] = edge[i]
                edge[i + 2] = edge[i]
            }
        }
        let sharp = try render(renderer, lut: nil, parameters: LookParameters(effects: LookEffects(nitidez: 1)),
                               pixels: edge)
        let soft = try render(renderer, lut: nil, parameters: LookParameters(effects: LookEffects(nitidez: -1)),
                              pixels: edge)
        let dark = (32 * 256 + 127) * 4, light = (32 * 256 + 128) * 4
        #expect(Int(sharp[light]) - Int(sharp[dark]) > 64)
        #expect(Int(soft[light]) - Int(soft[dark]) < 64)
        // Lejos del borde no cambia nada.
        #expect(sharp[(32 * 256 + 40) * 4] == 96 && sharp[(32 * 256 + 200) * 4] == 160)
    }

    @Test func clarityRaisesLocalContrast() throws {
        // Un cuadrado claro sobre gris medio: con claridad, el borde del cuadrado se separa más del
        // fondo (el entorno se mide sobre la fuente reducida, así que actúa cerca de los bordes).
        var pixels = [UInt8](repeating: 255, count: 256 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<256 {
                let i = (y * 256 + x) * 4
                let inside = (112..<144).contains(x) && (16..<48).contains(y)
                pixels[i] = inside ? 150 : 110
                pixels[i + 1] = pixels[i]
                pixels[i + 2] = pixels[i]
            }
        }
        let output = try render(renderer, lut: nil, parameters: LookParameters(effects: LookEffects(claridad: 1)),
                                pixels: pixels)
        let inside = (32 * 256 + 112) * 4, outside = (32 * 256 + 111) * 4
        #expect(Int(output[inside]) - Int(output[outside]) > 40 + 10)
        let softer = try render(renderer, lut: nil, parameters: LookParameters(effects: LookEffects(claridad: -1)),
                                pixels: pixels)
        #expect(Int(softer[inside]) - Int(softer[outside]) < 40 - 10)
        // Lejos del borde, nada.
        #expect(abs(Int(output[(32 * 256 + 20) * 4]) - 110) <= 1)
    }

    @Test func halationTintsAroundHighlightsOnly() throws {
        // Fondo oscuro con un cuadrado blanco: la halation enrojece alrededor del cuadrado y no lejos.
        var pixels = [UInt8](repeating: 255, count: 256 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<256 {
                let i = (y * 256 + x) * 4
                let inside = (120..<136).contains(x) && (24..<40).contains(y)
                pixels[i] = inside ? 255 : 30
                pixels[i + 1] = pixels[i]
                pixels[i + 2] = pixels[i]
            }
        }
        let output = try render(renderer, lut: nil, parameters: LookParameters(effects: LookEffects(halation: 1)),
                                pixels: pixels)
        let near = (32 * 256 + 137) * 4, far = (32 * 256 + 10) * 4
        #expect(Int(output[near]) > Int(output[near + 2]) + 8)  // más rojo que azul
        #expect(Int(output[near]) > 30 + 8)
        #expect(abs(Int(output[far]) - 30) <= 1 && abs(Int(output[far + 2]) - 30) <= 1)
        // Sin luces fuertes, ni halation ni bloom cambian nada.
        let gray = [UInt8](repeating: 128, count: 256 * 64 * 4)
        let flat = try render(renderer, lut: nil,
                              parameters: LookParameters(effects: LookEffects(halation: 1, bloom: 1)), pixels: gray)
        #expect(maxChannelDifference(gray, flat) <= 1)
    }

    @Test func rendersFullCGImage() throws {
        let pixels = testPattern()
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 256, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let lut = try renderer.makeLUTTexture(.identity())
        let output = try renderer.render(image: image, lut: lut, parameters: LookParameters())
        #expect(output.width == 256 && output.height == 64)
        let data = try #require(output.dataProvider?.data as Data?)
        #expect(maxChannelDifference(pixels, [UInt8](data)) == 0)
    }
}
