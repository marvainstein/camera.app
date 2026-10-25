import CaptureCore
import SwiftUI

/// Qué guías se ven en el visor. Se guardan en el teléfono.
struct ViewfinderGuides: Codable, Equatable {
    var grid = true
    var level = true
    var histogram = false

    private static let key = "guiasVisor"

    static func load() -> ViewfinderGuides {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .init()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// Cuadrícula de tercios sobre lo que va a salir en la foto (o el recorte).
struct GridOverlay: View {
    let rect: CGRect

    var body: some View {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.35), lineWidth: 0.75)
        .allowsHitTesting(false)
    }
}

/// Nivel, como en la cámara del iPhone: dos tramos fijos (los bordes del teléfono, en su orientación)
/// y uno en el medio que sigue el horizonte. Derecho, todo se pone amarillo.
struct LevelIndicator: View {
    let tilt: DeviceTilt

    var body: some View {
        let color: Color = tilt.isLevel ? .yellow : .white
        ZStack {
            HStack(spacing: 0) {
                Capsule().frame(width: 28, height: 1.5)
                Spacer(minLength: 64)
                Capsule().frame(width: 28, height: 1.5)
            }
            .frame(width: 120)
            .rotationEffect(.degrees(tilt.orientation.uiRotation))
            Capsule()
                .frame(width: tilt.isLevel ? 120 : 56, height: 1.5)
                .rotationEffect(.degrees(-tilt.angle))
        }
        .foregroundStyle(color)
        .shadow(color: .black.opacity(0.4), radius: 1)
        .opacity(tilt.isFlat ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: tilt.isLevel)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(tilt.isLevel ? "Nivel: derecho" : "Nivel: \(Int(tilt.tilt.rounded())) grados")
    }
}

/// Histograma de brillo: oscuros a la izquierda, claros a la derecha.
struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        Canvas { context, size in
            guard bins.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.white.opacity(0.75)))
        }
        .frame(width: 112, height: 52)
        .padding(8)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Lo que va sobre el visor entre los controles (nivel en el centro, histograma arriba a la izquierda),
/// girado para quien sostiene el teléfono: con el teléfono horizontal, "arriba a la izquierda" es la
/// esquina que le queda arriba a la izquierda a la persona.
struct ViewfinderHUD: View {
    let model: CameraModel

    var body: some View {
        GeometryReader { geometry in
            let tilt = model.motion.tilt
            let landscape = tilt.orientation.isLandscape
            let size = landscape ? CGSize(width: geometry.size.height, height: geometry.size.width) : geometry.size
            ZStack(alignment: .topLeading) {
                Color.clear
                if model.guides.histogram, !model.histogram.isEmpty {
                    HistogramView(bins: model.histogram)
                        .padding(8)
                }
            }
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(tilt.orientation.uiRotation))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .animation(.easeInOut(duration: 0.3), value: tilt.orientation)
            if model.guides.level {
                LevelIndicator(tilt: tilt)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}
