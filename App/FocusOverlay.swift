import SwiftUI

/// Foco por toque, como en la cámara del iPhone: un cuadrado amarillo donde se tocó y, al lado, un sol
/// que sube o baja con el brillo (arrastrar el dedo por el visor hacia arriba aclara). Con el teléfono
/// horizontal, el sol va a la derecha de quien lo sostiene y gira con él. Solo dibuja: los toques y
/// arrastres los recibe el visor (`MetalPreview`). Unos segundos después desaparece; el foco sigue fijo.
struct FocusOverlay: View {
    let model: CameraModel

    private static let squareSize: CGFloat = 76

    var body: some View {
        GeometryReader { geometry in
            if let point = model.focusPoint {
                let center = CGPoint(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                let rotation = model.motion.tilt.orientation.uiRotation
                ZStack {
                    square
                        .position(center)
                    if model.canAdjustBrightness {
                        sun
                            .rotationEffect(.degrees(rotation))
                            .position(Self.sunPosition(center: center, rotation: rotation, bounds: geometry.size))
                            .animation(.easeInOut(duration: 0.3), value: rotation)
                    }
                }
                .opacity(model.isFocusSquareVisible || model.isAdjustingBrightness ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: model.isFocusSquareVisible)
            }
        }
        .allowsHitTesting(false)
    }

    /// A la derecha del cuadrado para quien sostiene el teléfono (girado `rotation` grados); si ahí no
    /// entra en la pantalla, a su izquierda.
    static func sunPosition(center: CGPoint, rotation: Double, bounds: CGSize) -> CGPoint {
        let angle = rotation * .pi / 180
        let right = CGPoint(x: cos(angle), y: sin(angle))
        let distance = squareSize / 2 + 22
        let candidate = CGPoint(x: center.x + right.x * distance, y: center.y + right.y * distance)
        let margin: CGFloat = 26
        let fits = (margin...(bounds.width - margin)).contains(candidate.x)
            && (margin...(bounds.height - margin)).contains(candidate.y)
        return fits ? candidate : CGPoint(x: center.x - right.x * distance, y: center.y - right.y * distance)
    }

    private var square: some View {
        Rectangle()
            .strokeBorder(.yellow, lineWidth: 1.5)
            .frame(width: Self.squareSize, height: Self.squareSize)
            .keyframeAnimator(initialValue: 1.0, trigger: model.focusPoint) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                CubicKeyframe(1.35, duration: 0.01)
                CubicKeyframe(1.0, duration: 0.25)
            }
    }

    /// Línea vertical con el sol, que sube con el brillo.
    private var sun: some View {
        let bias = model.settings.exposureBias
        let range = model.exposureBiasRange
        let travel = CGFloat(range.upperBound - range.lowerBound) / 2 * CameraModel.pointsPerEV
        let offset = -CGFloat(bias) * CameraModel.pointsPerEV
        return ZStack {
            Capsule()
                .fill(.yellow.opacity(0.6))
                .frame(width: 1, height: travel * 2)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 18))
                .foregroundStyle(.yellow)
                .offset(y: offset)
            if model.isAdjustingBrightness {
                Text(bias.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.yellow)
                    .offset(x: 26, y: offset)
            }
        }
        .frame(width: 44, height: travel * 2 + 30)
    }
}
