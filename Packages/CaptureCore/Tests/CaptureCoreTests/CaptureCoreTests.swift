import CoreGraphics
import Foundation
import Testing
@testable import CaptureCore

private let limits = ExposureLimits(isoRange: 32...3200, shutterRange: (1.0 / 16000)...0.5, biasRange: -8...8)

@Suite struct ExposurePlanTests {
    @Test func programModeIsAutomaticWithBias() {
        let plan = ExposurePlan.resolve(CaptureSettings(exposureBias: -1.3), limits: limits,
                                        currentISO: 100, currentShutterSeconds: 1.0 / 60)
        #expect(plan == .automatic(bias: -1.3))
    }

    @Test func aperturePriorityKeepsAutoExposure() {
        let settings = CaptureSettings(program: .aperturePriority(fNumber: 2.8))
        #expect(ExposurePlan.resolve(settings, limits: limits, currentISO: 100, currentShutterSeconds: 0.01)
            == .automatic(bias: 0))
    }

    @Test func manualISOKeepsCurrentShutter() {
        let plan = ExposurePlan.resolve(CaptureSettings(iso: 400), limits: limits,
                                        currentISO: 100, currentShutterSeconds: 1.0 / 125)
        #expect(plan == .custom(iso: 400, shutterSeconds: 1.0 / 125))
    }

    @Test func manualShutterKeepsCurrentISO() {
        let plan = ExposurePlan.resolve(CaptureSettings(shutterSeconds: 1.0 / 1000), limits: limits,
                                        currentISO: 250, currentShutterSeconds: 1.0 / 60)
        #expect(plan == .custom(iso: 250, shutterSeconds: 1.0 / 1000))
    }

    @Test func valuesAreClampedToDeviceLimits() {
        let plan = ExposurePlan.resolve(CaptureSettings(exposureBias: 20, iso: 12800, shutterSeconds: 4),
                                        limits: limits, currentISO: 100, currentShutterSeconds: 0.01)
        #expect(plan == .custom(iso: 3200, shutterSeconds: 0.5))
        #expect(ExposurePlan.resolve(CaptureSettings(exposureBias: -20), limits: limits,
                                     currentISO: 100, currentShutterSeconds: 0.01) == .automatic(bias: -8))
    }

    @Test func stopsAreFilteredByLimits() {
        #expect(limits.shutterStops.first == 1.0 / 8000)
        #expect(limits.shutterStops.last == 0.5)
        #expect(limits.isoStops.first == 32)
        #expect(limits.isoStops.last == 3200)
    }
}

@Suite struct WhiteBalanceTests {
    @Test func gainsAreClampedToValidRange() {
        let clamped = WhiteBalanceMath.clampGains(SIMD3(0.8, 2.0, 5.0), maxGain: 4)
        #expect(clamped == SIMD3(1, 2, 4))
    }
}

#if os(iOS)
@Suite struct FocalLengthTests {
    @Test func mainCameraIsAbout24mm() {
        // Lente principal de los iPhone Pro: ~71,6° de campo horizontal ≈ 24 mm.
        let focal = CameraCapabilities.equivalentFocalLength(horizontalFieldOfView: 71.6)
        #expect(abs(focal - 24) < 0.3)
        #expect(CameraCapabilities.equivalentFocalLength(horizontalFieldOfView: 40) > 40)
    }
}
#endif

@Suite struct PhotoFormatTests {
    @Test func defaultIsRAWPlusJPEG() {
        #expect(CaptureSettings().photoFormat == .rawJPEG)
        #expect(PhotoFormat.rawJPEG.processed == .jpeg && PhotoFormat.rawJPEG.includesRAW)
        #expect(PhotoFormat.raw.processed == nil)
    }

    @Test func withoutRAWKeepsTheProcessedFormat() {
        #expect(PhotoFormat.rawJPEG.withoutRAW == .jpeg)
        #expect(PhotoFormat.rawHEIC.withoutRAW == .heic)
        #expect(PhotoFormat.raw.withoutRAW == .jpeg)
        #expect(PhotoFormat.allCases.allSatisfy { !$0.withoutRAW.includesRAW })
    }
}

@Suite struct FocusGeometryTests {
    @Test func centerStaysCentered() {
        #expect(FocusGeometry.devicePoint(fromFrame: CGPoint(x: 0.5, y: 0.5)) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func portraitCornersMapToTheLandscapeSensor() {
        // Arriba a la izquierda del visor vertical = abajo a la izquierda del sensor apaisado.
        #expect(FocusGeometry.devicePoint(fromFrame: CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 1))
        // Arriba a la derecha del visor = arriba a la izquierda del sensor.
        #expect(FocusGeometry.devicePoint(fromFrame: CGPoint(x: 1, y: 0)) == CGPoint(x: 0, y: 0))
        #expect(FocusGeometry.devicePoint(fromFrame: CGPoint(x: 0.25, y: 0.8)) == CGPoint(x: 0.8, y: 0.75))
    }

    @Test func pointsOutsideTheFrameAreClamped() {
        #expect(FocusGeometry.devicePoint(fromFrame: CGPoint(x: -0.2, y: 1.3)) == CGPoint(x: 1, y: 1))
    }
}

@Suite struct DeviceTiltTests {
    /// Gravedad de un teléfono vertical girado `degrees` en sentido horario (sin mirar al piso).
    private func tilt(_ degrees: Double, previous: DeviceTilt.Orientation = .portrait) -> DeviceTilt {
        let radians = degrees * .pi / 180
        return DeviceTilt.from(gravityX: sin(radians), y: -cos(radians), z: 0, previous: previous)
    }

    @Test func uprightIsLevel() {
        let upright = tilt(0)
        #expect(upright.orientation == .portrait && upright.isLevel && abs(upright.tilt) < 1e-9)
    }

    @Test func smallTurnsAreMeasured() {
        #expect(abs(tilt(3).tilt - 3) < 1e-9)
        #expect(abs(tilt(-2).tilt + 2) < 1e-9)
        #expect(!tilt(3).isLevel)
    }

    @Test func landscapeBothWays() {
        let clockwise = tilt(92)
        #expect(clockwise.orientation == .landscapeClockwise)
        #expect(abs(clockwise.tilt - 2) < 1e-9)
        #expect(clockwise.orientation.uiRotation == -90)
        #expect(tilt(-90).orientation == .landscapeCounterclockwise)
        #expect(tilt(-90).isLevel)
        #expect(tilt(180).orientation == .upsideDown)
    }

    @Test func doesNotFlickerAround45Degrees() {
        // De vertical a 50°: sigue vertical (margen); a 60°, pasa a horizontal; y de vuelta a 40°, sigue.
        #expect(tilt(50, previous: .portrait).orientation == .portrait)
        #expect(tilt(60, previous: .portrait).orientation == .landscapeClockwise)
        #expect(tilt(40, previous: .landscapeClockwise).orientation == .landscapeClockwise)
    }

    @Test func lyingFlatKeepsTheOrientationAndHidesTheLevel() {
        let flat = DeviceTilt.from(gravityX: 0.1, y: -0.1, z: -0.99, previous: .landscapeClockwise)
        #expect(flat.isFlat && !flat.isLevel)
        #expect(flat.orientation == .landscapeClockwise)
    }
}

@Suite struct CaptureOrientationTests {
    @Test func photoIsRotatedToStayUpright() {
        #expect(DeviceTilt.Orientation.portrait.captureRotationAngle == 90)
        #expect(DeviceTilt.Orientation.landscapeCounterclockwise.captureRotationAngle == 0)
        #expect(DeviceTilt.Orientation.landscapeClockwise.captureRotationAngle == 180)
        #expect(DeviceTilt.Orientation.upsideDown.captureRotationAngle == 270)
    }

    @Test func viewfinderPointsLandInThePhoto() {
        let topLeft = CGPoint(x: 0, y: 0)
        // Vertical: igual. Girado a la izquierda: la arriba-izquierda del visor queda abajo a la izquierda
        // de la foto apaisada; girado a la derecha, arriba a la derecha.
        #expect(DeviceTilt.Orientation.portrait.photoPoint(fromFrame: topLeft) == topLeft)
        #expect(DeviceTilt.Orientation.landscapeCounterclockwise.photoPoint(fromFrame: topLeft) == CGPoint(x: 0, y: 1))
        #expect(DeviceTilt.Orientation.landscapeClockwise.photoPoint(fromFrame: topLeft) == CGPoint(x: 1, y: 0))
        #expect(DeviceTilt.Orientation.upsideDown.photoPoint(fromFrame: topLeft) == CGPoint(x: 1, y: 1))
        // El centro siempre es el centro; girar a la izquierda y después a la derecha vuelve al punto.
        for orientation in DeviceTilt.Orientation.allCases {
            #expect(orientation.photoPoint(fromFrame: CGPoint(x: 0.5, y: 0.5)) == CGPoint(x: 0.5, y: 0.5))
        }
        let p = CGPoint(x: 0.25, y: 0.75)
        let ccw = DeviceTilt.Orientation.landscapeCounterclockwise, cw = DeviceTilt.Orientation.landscapeClockwise
        #expect(cw.photoPoint(fromFrame: ccw.photoPoint(fromFrame: p)) == p)
    }

    @Test func counterclockwiseMatchesTheSensor() {
        // Girado a la izquierda la foto es el sensor tal cual: coincide con el punto que se le pide al
        // foco de la cámara.
        let p = CGPoint(x: 0.3, y: 0.8)
        #expect(DeviceTilt.Orientation.landscapeCounterclockwise.photoPoint(fromFrame: p)
                == FocusGeometry.devicePoint(fromFrame: p))
    }
}

@Suite struct FlashTests {
    @Test func startsOffAndCyclesThroughTheModes() {
        #expect(CaptureSettings().flash == .off)
        #expect(FlashMode.off.next == .auto)
        #expect(FlashMode.auto.next == .on)
        #expect(FlashMode.on.next == .off)
    }
}
