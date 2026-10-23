import SwiftUI

/// Foco por toque, como en la cámara del iPhone: un cuadrado amarillo donde se tocó y, al lado, un sol
/// que sube o baja con el brillo (arrastrar el dedo por el visor hacia arriba aclara). Solo dibuja: los
/// toques y arrastres los recibe el visor (`MetalPreview`). Unos segundos después se atenúa.
struct FocusOverlay: View {
    let model: CameraModel
    @State private var isBright = true

    private static let squareSize: CGFloat = 76

    var body: some View {
        GeometryReader { geometry in
            if let point = model.focusPoint {
                let center = CGPoint(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                // El sol va a la derecha del cuadrado, o a la izquierda si no entra.
                let sunOnRight = center.x + Self.squareSize / 2 + 48 < geometry.size.width
                let sunX = center.x + (sunOnRight ? 1 : -1) * (Self.squareSize / 2 + 22)
                ZStack {
                    square
                        .position(center)
                    if model.canAdjustBrightness {
                        sun
                            .position(x: sunX, y: center.y)
                    }
                }
                .opacity(isBright || model.isAdjustingBrightness ? 1 : 0.5)
                .animation(.easeOut(duration: 0.3), value: isBright)
            }
        }
        .allowsHitTesting(false)
        .task(id: model.focusTaps) {
            isBright = true
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { isBright = false }
        }
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
