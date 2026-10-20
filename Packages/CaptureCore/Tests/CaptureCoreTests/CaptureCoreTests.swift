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
