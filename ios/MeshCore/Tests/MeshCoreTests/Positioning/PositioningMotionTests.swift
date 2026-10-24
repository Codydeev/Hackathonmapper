import XCTest
@testable import MeshCore

/// Axis and sign checks: get these wrong and every later accuracy number is meaningless.
final class PositioningMotionTests: XCTestCase {
    private let flat = PZ.Vec3(0, 0, -1)

    private func motion(_ t: Double, gravity: PZ.Vec3 = PZ.Vec3(0, 0, -1), accel: PZ.Vec3 = PZ.Vec3(0, 0, 0),
                        rotation: PZ.Vec3 = PZ.Vec3(0, 0, 0)) -> PZ.MotionSample {
        PZ.MotionSample(t: t, gravity: gravity, userAcceleration: accel, rotationRate: rotation)
    }

    func testTurningClockwiseIncreasesHeading() {
        // Flat, screen up: device z is up; a negative rotation about z is clockwise seen from above.
        XCTAssertEqual(PZ.DeviceAxes.headingRate(motion(0, rotation: PZ.Vec3(0, 0, -0.5)))!, 0.5, accuracy: 1e-12)
    }

    func testHeadingRateDoesNotDependOnHowThePhoneIsHeld() {
        // Upright in portrait: device y is up.
        let upright = motion(0, gravity: PZ.Vec3(0, -1, 0), rotation: PZ.Vec3(0, 0.3, 0))
        XCTAssertEqual(PZ.DeviceAxes.headingRate(upright)!, -0.3, accuracy: 1e-12)
    }

    /// Earth's field near Tampere expressed in a device frame whose forward axis points at `heading`.
    private func field(heading h: Double, upright: Bool) -> (b: PZ.Vec3, gravity: PZ.Vec3) {
        let east = PZ.Vec3(1, 0, 0), north = PZ.Vec3(0, 1, 0), up = PZ.Vec3(0, 0, 1)
        let world = north.scaled(15) - up.scaled(50)
        let forward = east.scaled(sin(h)) + north.scaled(cos(h))
        let right = east.scaled(cos(h)) - north.scaled(sin(h))
        let (x, y, z) = upright ? (right, up, forward.scaled(-1)) : (right, forward, up)
        let b = PZ.Vec3(world.dot(x), world.dot(y), world.dot(z))
        let g = PZ.Vec3(-up.dot(x), -up.dot(y), -up.dot(z))
        return (b, g)
    }

    func testCompassIsTiltCompensatedFlatAndUpright() {
        for degrees in [0.0, 37, 90, 181, 300] {
            let h = PZ.degrees(degrees)
            for upright in [false, true] {
                let (b, g) = field(heading: h, upright: upright)
                let out = PZ.Compass.heading(magneticField: b, gravity: g, declination: 0)!
                XCTAssertEqual(PZ.wrap(out.heading - h), 0, accuracy: 1e-9, "\(degrees)° upright \(upright)")
            }
        }
        let (b, g) = field(heading: 0, upright: false)
        let declined = PZ.Compass.heading(magneticField: b, gravity: g, declination: PZ.Compass.tampereDeclination)!
        XCTAssertEqual(declined.heading, PZ.Compass.tampereDeclination, accuracy: 1e-9, "true = magnetic + declination")
    }

    func testCompassDisturbanceIsDetected() {
        XCTAssertFalse(PZ.Compass.isDisturbed(strength: 52.5, dip: PZ.degrees(74)))
        XCTAssertTrue(PZ.Compass.isDisturbed(strength: 70, dip: PZ.degrees(74)), "steel nearby")
        XCTAssertTrue(PZ.Compass.isDisturbed(strength: 52, dip: PZ.degrees(55)))
    }

    func testStepDetectorCountsWalkingSteps() {
        var detector = PZ.StepDetector()
        var rng = SimRandom(seed: 4)
        var steps: [PZ.StepEvent] = []
        var t = 0.0
        while t < 30 {
            let a = 0.3 * sin(2 * .pi * 1.8 * t) + 0.02 * rng.gauss()
            if let s = detector.add(motion(t, gravity: flat, accel: PZ.Vec3(0, 0, a))) { steps.append(s) }
            t += 0.02
        }
        XCTAssertEqual(Double(steps.count), 54, accuracy: 3)
        let lengths = steps.dropFirst().map(\.length)
        XCTAssertEqual(lengths.reduce(0, +) / Double(lengths.count), 0.70, accuracy: 0.05, "Weinberg at 0.6 g peak to peak")
    }

    func testNoStepsWhileStill() {
        var detector = PZ.StepDetector()
        var rng = SimRandom(seed: 5)
        var count = 0
        for i in 0..<1_500 {
            if detector.add(motion(Double(i) * 0.02, accel: PZ.Vec3(0, 0, 0.003 * rng.gauss()))) != nil { count += 1 }
        }
        XCTAssertEqual(count, 0)
    }

    func testStillnessReportsTheGyroBias() {
        var still = PZ.StationarityDetector()
        var result: Double?
        for i in 0..<100 { result = still.add(motion(Double(i) * 0.02, rotation: PZ.Vec3(0, 0, -0.004))) }
        XCTAssertEqual(try XCTUnwrap(result), 0.004, accuracy: 1e-9)
        var walking = PZ.StationarityDetector()
        for i in 0..<100 {
            result = walking.add(motion(Double(i) * 0.02, accel: PZ.Vec3(0, 0, 0.3 * sin(Double(i) * 0.2))))
        }
        XCTAssertNil(result)
    }

    // MARK: - Frames through the engine

    private func walk(_ engine: PZ.Engine, from t0: Double, seconds: Double, rotation: Double = 0) -> Double {
        var t = t0
        while t < t0 + seconds {
            t += 0.02
            let a = 0.3 * sin(2 * .pi * 1.8 * (t - t0))
            engine.ingest(motion: motion(t, accel: PZ.Vec3(0, 0, a), rotation: PZ.Vec3(0, 0, rotation)))
        }
        return t
    }

    func testWalkingEastIsPositiveXAndNorthIsPositiveZ() {
        let engine = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        engine.declare(position: .zero, sigma: 1, at: 0)
        engine.ingest(compass: PZ.CompassSample(t: 0.01, heading: .pi / 2, sigma: PZ.degrees(3)))
        var t = walk(engine, from: 0.01, seconds: 10)
        let east = engine.estimate(at: t).position!
        XCTAssertGreaterThan(east.x, 9)
        XCTAssertEqual(east.z, 0, accuracy: 1.5)

        // A compass that jumps 90° while the gyro saw no turn is gated out as inconsistent...
        engine.ingest(compass: PZ.CompassSample(t: t + 0.01, heading: 0, sigma: PZ.degrees(3)))
        XCTAssertEqual(engine.estimate(at: t + 0.01).heading!, .pi / 2, accuracy: PZ.degrees(3))
        // ...a real left turn shows on the gyro.
        let turnEnd = t + 2
        while t < turnEnd {
            t += 0.02
            engine.ingest(motion: motion(t, rotation: PZ.Vec3(0, 0, Double.pi / 4)))
        }
        t = walk(engine, from: t, seconds: 10)
        let north = engine.estimate(at: t).position!
        XCTAssertGreaterThan(north.z - east.z, 9)
        XCTAssertEqual(north.x - east.x, 0, accuracy: 2.5)
    }

    func testGyroTurnRightWithoutCompass() {
        let engine = PZ.Engine(selfId: "phone-b", frameId: "hervanta-v1")
        engine.declare(position: .zero, sigma: 1, at: 0)
        engine.ingest(compass: PZ.CompassSample(t: 0.01, heading: 0, sigma: PZ.degrees(2)))
        // Turn 90° clockwise on the spot over 2 s, then walk.
        var t = 0.01
        while t < 2.01 {
            t += 0.02
            engine.ingest(motion: motion(t, rotation: PZ.Vec3(0, 0, -Double.pi / 4)))
        }
        XCTAssertEqual(engine.estimate(at: t).heading!, .pi / 2, accuracy: PZ.degrees(3))
        t = walk(engine, from: t, seconds: 10)
        let p = engine.estimate(at: t).position!
        XCTAssertGreaterThan(p.x, 9, "after a right turn from north the phone walks east")
        XCTAssertEqual(p.z, 0, accuracy: 2)
    }
}
