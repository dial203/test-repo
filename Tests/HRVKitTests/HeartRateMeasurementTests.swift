import XCTest
@testable import HRVKit

final class HeartRateMeasurementTests: XCTestCase {

    func testParsesUInt8HeartRateWithRRIntervals() {
        // flags 0x10 (8-bit HR, RR present), HR 60, RR = 1024 and 1010 (1/1024 s units)
        let data = Data([0x10, 60, 0x00, 0x04, 0xF2, 0x03])
        let m = HeartRateMeasurement(data: data)
        XCTAssertEqual(m?.heartRate, 60)
        XCTAssertEqual(m?.rrIntervals.count, 2)
        XCTAssertEqual(m!.rrIntervals[0], 1000.0, accuracy: 1e-9)          // 1024/1024 s
        XCTAssertEqual(m!.rrIntervals[1], 1010.0 * 1000 / 1024, accuracy: 1e-9)
        XCTAssertEqual(m?.sensorContact, .notSupported)
        XCTAssertNil(m?.energyExpended)
    }

    func testParsesUInt16HeartRateEnergyAndContact() {
        // flags 0x1F: 16-bit HR, contact supported+detected, energy present, RR present
        var bytes: [UInt8] = [0x1F, 0x2C, 0x01]        // HR = 300 (unrealistic but tests the width)
        bytes += [0x64, 0x00]                          // energy = 100
        bytes += [0x00, 0x02]                          // RR = 512 -> 500 ms
        let m = HeartRateMeasurement(data: Data(bytes))
        XCTAssertEqual(m?.heartRate, 300)
        XCTAssertEqual(m?.energyExpended, 100)
        XCTAssertEqual(m?.sensorContact, .detected)
        XCTAssertEqual(m!.rrIntervals[0], 500.0, accuracy: 1e-9)
    }

    func testHeartRateOnlyPacketYieldsNoIntervals() {
        let m = HeartRateMeasurement(data: Data([0x00, 55]))
        XCTAssertEqual(m?.heartRate, 55)
        XCTAssertTrue(m!.rrIntervals.isEmpty, "a strap in HR-only mode must not fabricate intervals")
    }

    func testRejectsTruncatedPacket() {
        XCTAssertNil(HeartRateMeasurement(data: Data([0x10])))
        XCTAssertNil(HeartRateMeasurement(data: Data()))
        // 16-bit HR flag but only one byte of HR present.
        XCTAssertNil(HeartRateMeasurement(data: Data([0x01, 0x2C])))
    }
}

final class BeatAccumulatorTests: XCTestCase {

    func testBeatsArePlacedByIntervalDurationNotArrivalTime() {
        var acc = BeatAccumulator()
        let t0 = Date.fixture
        acc.append(rrIntervals: [1000, 1000], receivedAt: t0)
        // Notification arrives late, but the reported intervals are what define the beats.
        acc.append(rrIntervals: [1000, 1000], receivedAt: t0.addingTimeInterval(2.4))

        let series = acc.makeSeries(sourceIdentifier: "test", deviceName: "strap")!
        XCTAssertEqual(series.beats.count, 5)
        XCTAssertEqual(series.beats.map(\.offset), [0, 1, 2, 3, 4])
        XCTAssertEqual(series.segments().first?.intervals.count, 4)
    }

    func testDropoutIsFlaggedAsAGap() {
        var acc = BeatAccumulator(dropoutTolerance: 2.0)
        let t0 = Date.fixture
        acc.append(rrIntervals: [1000, 1000], receivedAt: t0)
        // 30 s of wall clock passes but only 3 s of intervals are reported: a dropout.
        acc.append(rrIntervals: [1000, 1000, 1000], receivedAt: t0.addingTimeInterval(30))

        let series = acc.makeSeries(sourceIdentifier: nil, deviceName: nil)!
        XCTAssertEqual(series.beats.count, 6)
        XCTAssertTrue(series.beats[3].precededByGap)

        // The gap splits the run: 2 intervals before it and 2 after, so 2 successive
        // differences rather than the 4 a naive concatenation would produce.
        let segments = series.segments()
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.count), [2, 2])
        XCTAssertEqual(TimeDomain.metrics(for: segments).differenceCount, 2)
    }

    func testEmptyPacketsDoNotStartASeries() {
        var acc = BeatAccumulator()
        acc.append(rrIntervals: [], receivedAt: .fixture)
        XCTAssertNil(acc.makeSeries(sourceIdentifier: nil, deviceName: nil))
        XCTAssertEqual(acc.beatCount, 0)
    }
}
