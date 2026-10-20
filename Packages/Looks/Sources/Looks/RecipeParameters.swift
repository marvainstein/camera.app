import Foundation

extension FilmRecipe {
    /// Grupo de sliders del editor.
    public enum Group: String, Sendable, CaseIterable, Identifiable {
        case tono, color, virado, bn

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .tono: "Tono"
            case .color: "Color"
            case .virado: "Virado"
            case .bn: "B/N"
            }
        }
    }

    /// Un parámetro numérico de la receta, con el rango que muestra el editor.
    public struct Parameter: Identifiable {
        /// Clave en `looks.json`.
        public let id: String
        public let name: String
        public let group: Group
        public let range: ClosedRange<Double>
        public let keyPath: WritableKeyPath<FilmRecipe, Double>
    }

    /// Todos los parámetros numéricos menos `mono`, que es un interruptor. Los rangos cubren las
    /// recetas incluidas (lo verifica un test) y dejan margen para exagerar.
    public static var parameters: [Parameter] {
        [
            Parameter(id: "brillo", name: "Brillo", group: .tono, range: -4...4, keyPath: \.brillo),
            Parameter(id: "contraste", name: "Contraste", group: .tono, range: -0.5...0.6, keyPath: \.contraste),
            Parameter(id: "altas_luces", name: "Altas luces suaves", group: .tono, range: 0...1, keyPath: \.altasLuces),
            Parameter(id: "negros", name: "Negros levantados", group: .tono, range: 0...0.15, keyPath: \.negros),
            Parameter(id: "blancos", name: "Blancos", group: .tono, range: 0.85...1, keyPath: \.blancos),
            Parameter(id: "calidez", name: "Calidez", group: .color, range: -1...2, keyPath: \.calidez),
            Parameter(id: "tinte", name: "Tinte (verde/magenta)", group: .color, range: -6...6, keyPath: \.tinte),
            Parameter(id: "saturacion", name: "Saturación", group: .color, range: 0...1.6, keyPath: \.saturacion),
            Parameter(id: "rojos_amarillos", name: "Rojos y amarillos", group: .color, range: -0.5...0.5,
                      keyPath: \.rojosAmarillos),
            Parameter(id: "verdes_oliva", name: "Verdes hacia oliva", group: .color, range: -20...20,
                      keyPath: \.verdesOliva),
            Parameter(id: "verdes_apagados", name: "Verdes apagados", group: .color, range: -0.5...1,
                      keyPath: \.verdesApagados),
            Parameter(id: "azules_apagados", name: "Azules apagados", group: .color, range: -0.5...1,
                      keyPath: \.azulesApagados),
            Parameter(id: "sombras_frias", name: "Sombras frías", group: .virado, range: -2...3, keyPath: \.sombrasFrias),
            Parameter(id: "luces_amarillas", name: "Luces amarillas", group: .virado, range: -2...3,
                      keyPath: \.lucesAmarillas),
            Parameter(id: "virado_sombras", name: "Virado de sombras", group: .virado, range: 0...2,
                      keyPath: \.viradoSombras),
            Parameter(id: "virado_sombras_tono", name: "Tono de sombras (°)", group: .virado, range: 0...360,
                      keyPath: \.viradoSombrasTono),
            Parameter(id: "virado_luces", name: "Virado de luces", group: .virado, range: 0...2, keyPath: \.viradoLuces),
            Parameter(id: "virado_luces_tono", name: "Tono de luces (°)", group: .virado, range: 0...360,
                      keyPath: \.viradoLucesTono),
            Parameter(id: "filtro", name: "Filtro de color", group: .bn, range: 0...1, keyPath: \.filtro),
            Parameter(id: "filtro_tono", name: "Tono del filtro (°)", group: .bn, range: 0...360, keyPath: \.filtroTono),
        ]
    }

    /// Receta que deja la imagen como está (salvo redondeo): punto de partida de una receta nueva.
    public static let neutral = FilmRecipe(calidez: 0, altasLuces: 0, contraste: 0, negros: 0, blancos: 1,
                                           verdesOliva: 0, verdesApagados: 0, azulesApagados: 0,
                                           rojosAmarillos: 0, saturacion: 1, sombrasFrias: 0, lucesAmarillas: 0)

    /// La misma receta con cada parámetro dentro de su rango (los que no son números finitos
    /// vuelven al valor neutro). Para recetas que vienen de afuera.
    public var clamped: FilmRecipe {
        var out = self
        for parameter in Self.parameters {
            let value = self[keyPath: parameter.keyPath]
            out[keyPath: parameter.keyPath] = value.isFinite
                ? min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
                : Self.neutral[keyPath: parameter.keyPath]
        }
        out.mono = mono.isFinite && mono != 0 ? 1 : 0
        return out
    }
}
