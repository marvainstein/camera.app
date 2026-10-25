import CoreGraphics
import ImageIO
import Foundation
import Metal
import simd
import Testing
import UniformTypeIdentifiers
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
        #expect(looks.map(\.id) == ["natural"] + recipeLookIDs.filter { $0 != "natural" })
        for look in looks {
            #expect(look.recipe != nil && look.lut == nil, "\(look.id): todo Look incluido es una receta")
            #expect(try LookCatalog.lut(for: look, cacheDirectory: nil).size == 64)
        }
    }

    @Test func naturalIsTheIdentity() throws {
        let natural = try #require(try LookCatalog.bundled().first { $0.id == "natural" })
        let values = try LookCatalog.lut(for: natural, cacheDirectory: nil).floatTexels
        let identity = LUT3D.identity(size: 64).floatTexels
        #expect(zip(values, identity).allSatisfy { abs($0 - $1) <= 1 / 2048 })
    }
}

/// Referencias 17³ que escribe `scripts/make_luts.py export-reference` con `film_look()`.
private func pythonReference(_ id: String) throws -> LUT3D {
    let url = try #require(Bundle.module.url(forResource: id, withExtension: "lut"))
    return try LUT3D(contentsOf: url)
}

/// El catálogo, en orden.
private let recipeLookIDs = ["natural", "dorado-200", "retrato-400", "clasico", "documental", "contemporaneo", "puro",
                             "cine", "verde-azulado", "blanqueo", "plata-400", "bn-alto-contraste", "sepia"]

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
        let bundled = try #require(try LookCatalog.bundled().first { $0.id == "verde-azulado" })
        // Id propio: si otro test ya generó "verde-azulado", estaría en la caché de memoria y no se
        // escribiría en `directory`.
        let look = Look(id: "cache-\(UUID().uuidString)", name: bundled.name, recipe: bundled.recipe)
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
        let documental = try #require(looks.first { $0.id == "documental" })
        #expect(documental.effects == LookEffects(vineteo: 0.1))
        #expect(looks.first { $0.id == "dorado-200" }?.effects == LookEffects(halation: 0.25))
        #expect(looks.first { $0.id == "natural" }?.effects == nil)
    }

    @Test func lutKeyFollowsTheRecipe() throws {
        var recipe = FilmRecipe.neutral
        let a = Look(id: "propia-1", name: "A", recipe: recipe)
        recipe.calidez = 0.5
        let b = Look(id: "propia-1", name: "A", recipe: recipe)
        #expect(a.lutKey != b.lutKey)
        #expect(Look(id: "x", name: "X", lut: "x.lut").lutKey == "x-x.lut")
        #expect(Look(id: "x", name: "X", lut: "x.lut", recipe: recipe).lutKey != b.lutKey)
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
            try LookShare.text(for: Look(id: "x", name: "X", lut: "x.lut"))
        }
        #expect(throws: LookShare.Error.notARecipe) {
            try LookShare.text(for: Look(id: "x", name: "X", lut: "x.lut", recipe: .neutral))
        }
    }
}

@Suite struct CubeImportTests {
    /// .cube 2³ que invierte los colores, con dominio 0…2 (los valores de entrada se dividen por 2).
    private let invertCube = """
    # comentario
    TITLE "Invertir"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0 0 0
    DOMAIN_MAX 2 2 2
    1 1 1
    0 1 1
    1 0 1
    0 0 1
    1 1 0
    0 1 0
    1 0 0
    0 0 0
    """

    @Test func readsAndResamplesACube() throws {
        let lut = try LUT3D(cube: invertCube, size: 17)
        #expect(lut.size == 17)
        // Entrada 0.5 → dominio 0.25 → invertido 0.75 (trilineal exacto en un 2³ lineal).
        let out = lut.apply(SIMD3(0.5, 0.5, 0.5))
        #expect(abs(out.x - 0.75) < 2e-3 && abs(out.y - 0.75) < 2e-3 && abs(out.z - 0.75) < 2e-3)
        let black = lut.apply(SIMD3(0, 0, 0))
        #expect(abs(black.x - 1) < 1e-3)
    }

    @Test func rejectsWhatItCannotRead() {
        #expect(throws: LUT3D.CubeError.notA3DLUT) { try LUT3D(cube: "0 0 0\n1 1 1") }
        #expect(throws: LUT3D.CubeError.has1DLUT) { try LUT3D(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1") }
        #expect(throws: LUT3D.CubeError.wrongRowCount(expected: 8, actual: 1)) {
            try LUT3D(cube: "LUT_3D_SIZE 2\n0 0 0")
        }
        #expect(throws: LUT3D.CubeError.badRow(2)) { try LUT3D(cube: "LUT_3D_SIZE 2\n0 x 0") }
    }

    @Test func neutralRecipeKeepsTheBaseLUT() throws {
        let base = try LUT3D(cube: invertCube, size: 17)
        let combined = FilmRecipe.neutral.makeLUT(size: 17, base: base)
        let worst = zip(base.floatTexels, combined.floatTexels).map { abs($0 - $1) }.max() ?? 1
        #expect(worst <= 1 / 2048)
        var warm = FilmRecipe.neutral
        warm.calidez = 1
        #expect(warm.makeLUT(size: 17, base: base) != combined)
    }

    @Test func importedCubeIsARecipeOnTopOfTheLUT() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LooksTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UserLookStore(url: folder.appendingPathComponent("user-looks.json"))
        let look = try store.importCube(invertCube, name: " Invertir ")
        #expect(look.name == "Invertir" && look.recipe == .neutral && look.lut == look.id + ".lut")
        #expect(FileManager.default.fileExists(atPath: store.lutDirectory.appendingPathComponent(look.lut!).path))

        let lut = try LookCatalog.lut(for: look, cacheDirectory: nil, userLUTDirectory: store.lutDirectory)
        let out = lut.apply(SIMD3(0, 0, 0))
        #expect(abs(out.x - 1) < 2e-3)  // el negro sale blanco: se aplicó el .cube

        store.removeLUTFile(of: look, remaining: [])
        #expect(!FileManager.default.fileExists(atPath: store.lutDirectory.appendingPathComponent(look.lut!).path))
    }
}

@Suite struct PhotoAdjustmentTests {
    @Test func roundTrip() throws {
        let look = try #require(try LookCatalog.bundled().first { $0.id == "cine" })
        let adjustment = PhotoAdjustment(look: look, intensity: 0.8,
                                         framing: Framing(focalLength: 50, aspect: .threeTwo), lensFocalLength: 24)
        let decoded = try #require(PhotoAdjustment(data: adjustment.encoded()))
        #expect(decoded == adjustment)
        #expect(decoded.look.lutKey == look.lutKey)
    }

    @Test func ignoresForeignData() {
        #expect(PhotoAdjustment(data: Data("no es nuestro".utf8)) == nil)
        #expect(PhotoAdjustment(data: Data("{}".utf8)) == nil)
    }
}

@Suite struct FramingTests {
    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9
            && abs(a.height - b.height) < 1e-9
    }

    @Test func fullFrameIsTheWholeImage() {
        let r = Framing().rect(in: CGSize(width: 3, height: 4), lensFocalLength: 24)
        #expect(close(r, CGRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(Framing().isFullFrame && !Framing(focalLength: 50).isFullFrame)
    }

    @Test func doubleFocalLengthKeepsHalfTheSides() {
        let r = Framing(focalLength: 48).rect(in: CGSize(width: 3, height: 4), lensFocalLength: 24)
        #expect(close(r, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        // Una focal más corta que el lente no agranda nada.
        let wide = Framing(focalLength: 18).rect(in: CGSize(width: 3, height: 4), lensFocalLength: 24)
        #expect(close(wide, CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    @Test func aspectFollowsTheImageOrientation() {
        // En una foto vertical 3:4, el 3:2 queda 2:3 (más alto que 3:4): se recortan los costados.
        let portrait = Framing(aspect: .threeTwo).rect(in: CGSize(width: 3000, height: 4000), lensFocalLength: 24)
        #expect(abs(portrait.height - 1) < 1e-9)
        #expect(abs(portrait.width * 3000 / (portrait.height * 4000) - 2.0 / 3.0) < 1e-9)
        let square = Framing(aspect: .square).rect(in: CGSize(width: 4000, height: 3000), lensFocalLength: 24)
        #expect(abs(square.width * 4000 - square.height * 3000) < 1e-6 && abs(square.height - 1) < 1e-9)
    }

    @Test func storedRectFollowsEXIFOrientation() {
        let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        #expect(close(Framing.storedRect(r, orientation: 1), r))
        #expect(close(Framing.storedRect(r, orientation: 3), CGRect(x: 0.6, y: 0.4, width: 0.3, height: 0.4)))
        #expect(close(Framing.storedRect(r, orientation: 6), CGRect(x: 0.2, y: 0.6, width: 0.4, height: 0.3)))
        #expect(close(Framing.storedRect(r, orientation: 8), CGRect(x: 0.4, y: 0.1, width: 0.4, height: 0.3)))
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
        let bw = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == "plata-400" }),
                                     cacheDirectory: nil)
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

    @Test(arguments: ["plata-400", "bn-alto-contraste"])
    func blackAndWhiteLookIsNeutral(id: String) throws {
        let bw = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == id }), cacheDirectory: nil)
        let output = try render(renderer, lut: bw, parameters: LookParameters())
        for i in stride(from: 0, to: output.count, by: 4) {
            #expect(abs(Int(output[i]) - Int(output[i + 1])) <= 1)
            #expect(abs(Int(output[i + 1]) - Int(output[i + 2])) <= 1)
        }
    }

    @Test func gpuMatchesCPUReference() throws {
        let warm = try LookCatalog.lut(for: #require(try LookCatalog.bundled().first { $0.id == "dorado-200" }),
                                       cacheDirectory: nil)
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

    @Test func aspectFitShowsTheWholeSourceWithBars() throws {
        let uv = LookRenderer.uvTransform(source: (200, 100), destination: (100, 100), contentMode: .aspectFit)
        #expect(uv.x == 1 && uv.y == 2 && uv.z == 0 && uv.w == -0.5)
        // Fuente apaisada en un destino cuadrado: arriba y abajo quedan bandas negras.
        let source = try renderer.makeTexture(rgba8: [UInt8](repeating: 200, count: 64 * 32 * 4), width: 64, height: 32)
        let target = try renderer.makeRenderTarget(width: 64, height: 64)
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(commandBuffer: commandBuffer, source: source, lut: nil, destination: target,
                            parameters: LookParameters(), contentMode: .aspectFit)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let output = try renderer.readBytes(target)
        #expect(output[(2 * 64 + 32) * 4] == 0)        // banda de arriba
        #expect(output[(32 * 64 + 32) * 4] == 200)     // centro: la foto
        #expect(output[(61 * 64 + 32) * 4] == 0)       // banda de abajo
    }

    @Test func splitShowsTheOriginalOnTheLeft() throws {
        let gray = [UInt8](repeating: 100, count: 256 * 64 * 4)
        let lut = LUT3D(size: 8) { _ in SIMD3(1, 1, 1) }  // todo blanco
        let output = try render(renderer, lut: lut, parameters: LookParameters(split: 0.5), pixels: gray)
        #expect(output[(32 * 256 + 40) * 4] == 100)    // izquierda: sin Look
        #expect(output[(32 * 256 + 220) * 4] == 255)   // derecha: con Look
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

    @Test func previewTextureFromPhotoFollowsOrientation() throws {
        // JPEG apaisado de 64×32 marcado con orientación 6 (rotar 90°): en el visor tiene que quedar parado.
        let pixels = [UInt8](repeating: 200, count: 64 * 32 * 4)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 64, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let texture = try renderer.makePreviewTexture(photo: data as Data)
        #expect(texture.width == 32 && texture.height == 64)
        let bytes = try renderer.readBytes(texture)
        #expect(abs(Int(bytes[0]) - 200) <= 3)
        #expect(throws: LookRendererError.self) { try renderer.makePreviewTexture(photo: Data("no es una foto".utf8)) }
    }

    @Test func renderPhotoCropsToTheFrame() throws {
        // JPEG vertical (orientación 6, guardado apaisado 64×48) recortado a 2× la focal: sale derecho,
        // 24×32.
        let pixels = [UInt8](repeating: 120, count: 64 * 48 * 4)
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 64, height: 48, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let output = try renderer.renderPhoto(data as Data, lut: nil, parameters: LookParameters(),
                                              framing: Framing(focalLength: 48), lensFocalLength: 24,
                                              outputType: .jpeg)
        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(result.width == 24 && result.height == 32)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }

    @Test func renderPhotoComesOutUpright() throws {
        // Guardada apaisada (8×4) con orientación 6 (girar 90° a la derecha para verla). La mitad
        // izquierda guardada es roja: en la foto derecha, es la mitad de arriba.
        var pixels = [UInt8](repeating: 255, count: 8 * 4 * 4)
        for y in 0..<4 {
            for x in 0..<8 {
                let i = (y * 8 + x) * 4
                pixels[i] = 255
                pixels[i + 1] = x < 4 ? 0 : 255
                pixels[i + 2] = x < 4 ? 0 : 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: 8, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFMake: "Apple"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let output = try renderer.renderPhoto(data as Data, lut: nil, parameters: LookParameters(), outputType: .png)
        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(result.width == 4 && result.height == 8)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect((tiff?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "Apple")
        let rgba = try #require(result.dataProvider?.data as Data?)
        let bytesPerRow = result.bytesPerRow, bytesPerPixel = result.bitsPerPixel / 8
        // Arriba roja, abajo blanca.
        #expect(rgba[1 * bytesPerRow + 1 * bytesPerPixel + 1] < 30)
        #expect(rgba[6 * bytesPerRow + 1 * bytesPerPixel + 1] > 225)
    }

    @Test func uprightPropertiesDropTheOriginalProcessing() {
        let properties = LookRenderer.uprightProperties([
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyPixelWidth: 4032,
            kCGImagePropertyMakerAppleDictionary: ["33": 1.0],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 4032,
                                             kCGImagePropertyExifFNumber: 1.78],
        ])
        #expect((properties[kCGImagePropertyOrientation] as? Int) == 1)
        #expect(properties[kCGImagePropertyPixelWidth] == nil)
        #expect(properties[kCGImagePropertyMakerAppleDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifPixelXDimension] == nil)
        #expect((exif?[kCGImagePropertyExifFNumber] as? Double) == 1.78)
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

@Suite struct BokehTests {
    @Test func radiusIsInverselyProportionalToFNumber() {
        let wide = Bokeh(fNumber: 1.4), half = Bokeh(fNumber: 2.8)
        #expect(abs(wide.radiusFraction / half.radiusFraction - 2) < 1e-5)
        #expect(abs(wide.radius(shortSide: 3000) - 66) < 0.01)
    }

    @Test func closedApertureBarelyBlurs() {
        // f/16 en una foto de 12 MP: unos pocos píxeles; en una miniatura, nada.
        #expect(Bokeh(fNumber: 16).radius(shortSide: 3024) < 6)
        #expect(Bokeh(fNumber: 16).radius(shortSide: 100) < Bokeh.minimumRadius)
    }

    @Test func workScaleCapsTheRadius() {
        #expect(abs(66 * Bokeh.workScale(radius: 66) - BokehQuality.photo.workRadius) < 1e-4)
        #expect(abs(66 * Bokeh.workScale(radius: 66, quality: .preview) - BokehQuality.preview.workRadius) < 1e-4)
        #expect(Bokeh.workScale(radius: 8) == 1)
    }

    @Test func discIsRoundWideOpenAndShowsTheBladesClosed() {
        #expect(Bokeh(fNumber: 1.4).roundness == 1)
        #expect(Bokeh(fNumber: 2.8).roundness > 0 && Bokeh(fNumber: 2.8).roundness < 1)
        #expect(Bokeh(fNumber: 4).roundness == 0)
        #expect(Bokeh(fNumber: 11).roundness == 0)
    }

    @Test func visibleOnlyWhenTheBlurShows() {
        #expect(Bokeh(fNumber: 1.4).isVisible(shortSide: 1440))
        #expect(!Bokeh(fNumber: 16).isVisible(shortSide: 300))
    }

    @Test func blendingSmoothsTheMatteBetweenFrames() {
        let previous = PersonMatte(width: 2, height: 1, pixels: [0, 200])
        let current = PersonMatte(width: 2, height: 1, pixels: [100, 0])
        #expect(current.blended(withPrevious: previous, weight: 0.6).pixels == [60, 80])
        #expect(current.blended(withPrevious: nil, weight: 0.6) == current)
        // Si cambió el tamaño, no se mezcla.
        let other = PersonMatte(width: 1, height: 2, pixels: [255, 255])
        #expect(current.blended(withPrevious: other, weight: 0.6) == current)
    }

    @Test func matteCoverage() {
        let matte = PersonMatte(width: 4, height: 2, pixels: [255, 255, 0, 0, 200, 0, 0, 10])
        #expect(matte.coverage == 3.0 / 8)
    }

    @Test func adjustmentKeepsTheBokeh() throws {
        let look = Look(id: "natural", name: "Natural", recipe: .neutral)
        let adjustment = PhotoAdjustment(look: look, intensity: 1, framing: Framing(), lensFocalLength: 24,
                                         bokeh: Bokeh(fNumber: 2))
        #expect(PhotoAdjustment(data: try adjustment.encoded())?.bokeh == Bokeh(fNumber: 2))
    }

    @Test func adjustmentsSavedBeforeTheBokehHaveNone() throws {
        // Como las guardaba la versión anterior: sin la clave "bokeh".
        let look = Look(id: "natural", name: "Natural", recipe: .neutral)
        let old = PhotoAdjustment(look: look, intensity: 1, framing: Framing(), lensFocalLength: 24)
        let json = String(decoding: try old.encoded(), as: UTF8.self)
        #expect(!json.contains("bokeh"))
        let decoded = try #require(PhotoAdjustment(data: Data(json.utf8)))
        #expect(decoded.bokeh == nil)
    }

    @Test(arguments: [1, 3, 6, 8])
    func displayedPointTransformInvertsStoredRect(orientation: Int) {
        let t = Framing.displayedPointTransform(orientation: orientation)
        for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.4), CGPoint(x: 0.9, y: 0.95)] {
            let stored = Framing.storedRect(CGRect(origin: point, size: .zero), orientation: orientation).origin
            let p = SIMD3<Float>(Float(stored.x), Float(stored.y), 1)
            #expect(abs(Double(simd_dot(t.x, p)) - point.x) < 1e-6)
            #expect(abs(Double(simd_dot(t.y, p)) - point.y) < 1e-6)
        }
    }
}

@Suite(.enabled(if: hasMetal, "No hay dispositivo Metal")) struct BokehPipelineTests {
    let renderer: LookRenderer
    // Lado corto 300: a f/1.4 el radio es 6,6 px y se desenfoca a resolución completa.
    let width = 400, height = 300

    init() throws {
        renderer = try LookRenderer()
    }

    private func image(_ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
            }
        }
        return pixels
    }

    /// Persona en la mitad izquierda (x < 200).
    private var leftHalfPerson: PersonMatte {
        PersonMatte(width: width, height: height,
                    pixels: (0..<(width * height)).map { $0 % width < width / 2 ? 255 : 0 })
    }

    /// Rayas verticales de un píxel: el detalle más fino posible.
    private var stripes: [UInt8] {
        image { x, _ in x % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
    }

    private func bokeh(_ pixels: [UInt8], matte: PersonMatte, fNumber: Float = 1.4, orientation: Int = 1,
                       quality: BokehQuality = .photo, scratch: BokehScratch? = nil) throws -> [UInt8] {
        let source = try renderer.makeTexture(rgba8: pixels, width: width, height: height)
        let target = try renderer.makeRenderTarget(width: width, height: height)
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        try renderer.encodeBokeh(commandBuffer: commandBuffer, source: source, matte: renderer.makeTexture(matte: matte),
                                 destination: target, bokeh: Bokeh(fNumber: fNumber), orientation: orientation,
                                 quality: quality, scratch: scratch)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try renderer.readBytes(target)
    }

    private func channel(_ pixels: [UInt8], _ x: Int, _ y: Int, _ c: Int = 0) -> Int {
        Int(pixels[(y * width + x) * 4 + c])
    }

    /// Diferencia máxima entre píxeles vecinos de una fila, en un rango de x.
    private func roughness(_ pixels: [UInt8], xs: Range<Int>, y: Int = 150) -> Int {
        xs.dropLast().map { abs(channel(pixels, $0, y) - channel(pixels, $0 + 1, y)) }.max() ?? 0
    }

    @Test func personStaysSharpAndBackgroundBlurs() throws {
        let input = stripes
        let output = try bokeh(input, matte: leftHalfPerson)
        for y in stride(from: 0, to: height, by: 7) {
            for x in 0..<190 {
                #expect(channel(output, x, y) == channel(input, x, y))
            }
        }
        #expect(roughness(input, xs: 220..<390) == 255)
        #expect(roughness(output, xs: 220..<390) < 12)
    }

    @Test func personDoesNotBleedIntoTheBackground() throws {
        // Persona roja, fondo gris: al lado del borde el fondo tiene que seguir gris, no rojizo.
        let input = image { x, _ in x < 200 ? (255, 0, 0) : (128, 128, 128) }
        let output = try bokeh(input, matte: leftHalfPerson)
        for x in [204, 210, 300] {
            #expect(abs(channel(output, x, 150, 0) - 128) <= 2)
            #expect(abs(channel(output, x, 150, 1) - 128) <= 2)
        }
    }

    @Test func pointOfLightBecomesADisc() throws {
        // Un punto blanco sobre fondo oscuro, sin persona: un disco de radio ~6,6 px.
        let input = image { x, y in abs(x - 200) <= 1 && abs(y - 150) <= 1 ? (255, 255, 255) : (10, 10, 10) }
        let output = try bokeh(input, matte: PersonMatte(width: 4, height: 4, pixels: Array(repeating: 0, count: 16)))
        #expect(channel(output, 203, 150) > 100)
        #expect(channel(output, 200, 154) > 100)
        #expect(abs(channel(output, 212, 150) - 10) <= 2)
        #expect(abs(channel(output, 200, 162) - 10) <= 2)
    }

    @Test func previewMakesTheSameSizeDisc() throws {
        // El visor usa menos puntos, pero el disco tiene que medir lo mismo que en la foto.
        let input = image { x, y in abs(x - 200) <= 1 && abs(y - 150) <= 1 ? (255, 255, 255) : (10, 10, 10) }
        let noPerson = PersonMatte(width: 4, height: 4, pixels: Array(repeating: 0, count: 16))
        let output = try bokeh(input, matte: noPerson, quality: .preview)
        #expect(channel(output, 203, 150) > 60)
        #expect(channel(output, 200, 154) > 60)
        #expect(abs(channel(output, 212, 150) - 10) <= 2)
        #expect(abs(channel(output, 200, 162) - 10) <= 2)
    }

    @Test func previewKeepsThePersonSharp() throws {
        let input = stripes
        let output = try bokeh(input, matte: leftHalfPerson, quality: .preview)
        for x in 0..<190 {
            #expect(channel(output, x, 150) == channel(input, x, 150))
        }
        #expect(roughness(output, xs: 220..<390) < 20)
    }

    @Test func scratchTexturesAreReused() throws {
        let scratch = BokehScratch()
        _ = try bokeh(stripes, matte: leftHalfPerson, quality: .preview, scratch: scratch)
        let prepared = try #require(scratch.prepared), blurred = try #require(scratch.blurred)
        _ = try bokeh(stripes, matte: leftHalfPerson, quality: .preview, scratch: scratch)
        #expect(scratch.prepared === prepared)
        #expect(scratch.blurred === blurred)
    }

    @Test func compareShowsTheOriginalOnTheLeft() throws {
        // Del lado "antes" va la imagen sin bokeh (original), no la fuente que recibe el Look.
        let shown = try renderer.makeTexture(rgba8: image { _, _ in (255, 255, 255) }, width: width, height: height)
        let original = try renderer.makeTexture(rgba8: image { _, _ in (0, 0, 0) }, width: width, height: height)
        let target = try renderer.makeRenderTarget(width: width, height: height)
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        try renderer.encode(commandBuffer: commandBuffer, source: shown, lut: nil, destination: target,
                            parameters: LookParameters(split: 0.5), original: original)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let output = try renderer.readBytes(target)
        #expect(channel(output, 50, 150) == 0)
        #expect(channel(output, 350, 150) == 255)
    }

    @Test func matteFollowsTheEXIFOrientation() throws {
        // Guardada girada (6): la mitad de arriba de la foto derecha es la mitad izquierda guardada.
        let input = stripes
        let upright = PersonMatte(width: height, height: width,
                                  pixels: (0..<(width * height)).map { $0 / height < width / 2 ? 255 : 0 })
        let output = try bokeh(input, matte: upright, orientation: 6)
        #expect(roughness(output, xs: 10..<190) == 255)
        #expect(roughness(output, xs: 220..<390) < 12)
    }

    @Test func applyBokehSkipsWhenItWouldNotShow() throws {
        let provider = try #require(CGDataProvider(data: Data(stripes) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        // f/16 sobre 300 px: radio 0,6 px, no se aplica.
        let same = try renderer.applyBokeh(Bokeh(fNumber: 16), to: image, matte: leftHalfPerson, orientation: 1)
        #expect(same === image)
        let blurred = try renderer.applyBokeh(Bokeh(fNumber: 1.4), to: image, matte: leftHalfPerson, orientation: 1)
        #expect(blurred.width == width && blurred.height == height)
    }
}

@Suite struct LookCategoryTests {
    @Test func bundledLooksAreSortedIntoColorAndMonochrome() throws {
        let looks = try LookCatalog.bundled()
        let mono = Set(looks.filter { LookCatalog.category(of: $0, userLUTDirectory: nil) == .monochrome }.map(\.id))
        #expect(mono == ["plata-400", "bn-alto-contraste", "sepia"])
    }

    @Test func importedLUTsAreClassifiedByWhatTheyDo() {
        #expect(!LUT3D.identity(size: 17).isMonochrome)
        // Gris, sepia (tono fijo) y un filtro rojo (más brillo a los rojos, pero sin color): blanco y negro.
        let gray = LUT3D(size: 17) { c in SIMD3(repeating: (c * SIMD3(0.2126, 0.7152, 0.0722)).sum()) }
        let sepia = LUT3D(size: 17) { c in (c * SIMD3(0.2126, 0.7152, 0.0722)).sum() * SIMD3(1.07, 0.98, 0.82) }
        let redFilter = LUT3D(size: 17) { c in SIMD3(repeating: min(1, 0.8 * c.x + 0.2 * c.y)) }
        #expect(gray.isMonochrome && sepia.isMonochrome && redFilter.isMonochrome)
        // Desaturado pero con color: sigue siendo color.
        let faded = LUT3D(size: 17) { c in
            let luma = (c * SIMD3(0.2126, 0.7152, 0.0722)).sum()
            return SIMD3(repeating: luma) + (c - luma) * 0.3
        }
        #expect(!faded.isMonochrome)
    }

    @Test func favoritesComeRightAfterNatural() {
        let looks = ["natural", "dorado", "cine", "plata", "sepia"].map { Look(id: $0, name: $0, recipe: .neutral) }
        let arranged = LookOrder.arranged(looks, favorites: ["sepia", "cine"])
        #expect(arranged.map(\.id) == ["natural", "cine", "sepia", "dorado", "plata"])
        #expect(LookOrder.arranged(looks, favorites: []).map(\.id) == looks.map(\.id))
    }
}
