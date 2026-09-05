import Foundation
import CoreBluetooth
import HealthKit
import HRVKit
import os

/// Records beat-to-beat intervals from a Bluetooth chest strap and writes them into
/// HealthKit as `HKHeartbeatSeriesSample`s.
///
/// Why this exists: Apple Watch does not give third-party apps live beat-to-beat data,
/// and its own background heartbeat series are recorded only occasionally, so a night of
/// passive watch data yields a handful of ~60 s windows. If you need a dense, continuous
/// overnight RR series — for a five-minute-window analysis, for frequency-domain indices,
/// or as the criterion measure in an agreement study — it has to come from a sensor that
/// exposes RR intervals over the standard Heart Rate Service. Polar H10, Garmin HRM-Pro
/// and Movesense all do.
///
/// Data written this way is tagged with the strap as its `HKDevice`, so downstream
/// analysis can always separate it from the watch's own samples.
@MainActor
final class ExternalSensorRecorder: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case bluetoothUnavailable(String)
        case scanning
        case connecting(String)
        case recording(deviceName: String, beats: Int)
        case finished(beats: Int, seriesWritten: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastHeartRate: Int?
    @Published private(set) var sensorContact: HeartRateMeasurement.SensorContact = .notSupported
    /// Packets that arrived carrying no RR intervals. A strap reporting only heart rate
    /// cannot support HRV, and the user needs to be told rather than left with an empty
    /// night.
    @Published private(set) var packetsWithoutIntervals = 0

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var accumulator = BeatAccumulator()
    private var builder: HKHeartbeatSeriesBuilder?
    private var builderBeatCount = 0
    private var seriesWritten = 0
    private var deviceName: String?

    private let healthStore: HKHealthStore
    private let log = Logger(subsystem: "app.nocturne", category: "ble")

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
        super.init()
    }

    override convenience init() {
        self.init(healthStore: HKHealthStore())
    }

    // MARK: - Control

    func start() {
        guard central == nil else { return }
        accumulator.reset()
        seriesWritten = 0
        packetsWithoutIntervals = 0
        state = .scanning
        // State restoration lets iOS hand the connection back after the app is suspended
        // overnight, which is the whole point of this recorder.
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "app.nocturne.hrm"]
        )
    }

    func stop() async {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        await finishCurrentSeries()
        central = nil
        peripheral = nil
        state = .finished(beats: accumulator.beatCount, seriesWritten: seriesWritten)
    }

    // MARK: - HealthKit writing

    /// `HKHeartbeatSeriesBuilder` caps how many beats one sample can hold, so a long night
    /// is written as a chain of series rather than one oversized sample.
    private var builderIsFull: Bool {
        builderBeatCount >= HKHeartbeatSeriesBuilder.maximumCount - 1
    }

    private func ensureBuilder(start: Date) {
        guard builder == nil else { return }
        let device = HKDevice(
            name: deviceName, manufacturer: nil, model: nil, hardwareVersion: nil,
            firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
        builder = HKHeartbeatSeriesBuilder(healthStore: healthStore, device: device, start: start)
        builderBeatCount = 0
    }

    private func record(intervals: [Double], receivedAt: Date) async {
        let before = accumulator.beatCount
        accumulator.append(rrIntervals: intervals, receivedAt: receivedAt)
        guard let seriesStart = accumulator.start else { return }
        ensureBuilder(start: seriesStart)

        for beat in accumulator.beats.dropFirst(before) {
            if builderIsFull { await finishCurrentSeries(); ensureBuilder(start: seriesStart) }
            do {
                try await builder?.addHeartbeat(at: beat.offset, precededByGap: beat.precededByGap)
                builderBeatCount += 1
            } catch {
                log.error("addHeartbeat failed: \(error.localizedDescription)")
            }
        }
        state = .recording(deviceName: deviceName ?? "Heart rate sensor",
                           beats: accumulator.beatCount)
    }

    private func finishCurrentSeries() async {
        guard let builder else { return }
        self.builder = nil
        do {
            _ = try await builder.finishSeries()
            seriesWritten += 1
        } catch {
            log.error("finishSeries failed: \(error.localizedDescription)")
            state = .failed("Could not save the recorded beats: \(error.localizedDescription)")
        }
    }
}

extension ExternalSensorRecorder: CBCentralManagerDelegate {

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Required for state restoration; the reconnect itself is driven by the delegate
        // callbacks that follow.
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let cbState = central.state
        Task { @MainActor in
            switch cbState {
            case .poweredOn:
                self.state = .scanning
                central.scanForPeripherals(withServices: [Self.heartRateService])
            case .poweredOff:
                self.state = .bluetoothUnavailable("Bluetooth is off.")
            case .unauthorized:
                self.state = .bluetoothUnavailable("Bluetooth permission was denied.")
            case .unsupported:
                self.state = .bluetoothUnavailable("This device has no Bluetooth LE radio.")
            default:
                self.state = .bluetoothUnavailable("Bluetooth is not ready.")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? "Heart rate sensor"
        central.stopScan()
        Task { @MainActor in
            self.deviceName = name
            self.peripheral = peripheral
            self.state = .connecting(name)
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.heartRateService])
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        // Straps drop out overnight. Reconnect rather than ending the recording; the
        // dropout is already marked in the beat train as a gap.
        central.connect(peripheral)
    }
}

extension ExternalSensorRecorder: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService })
        else { return }
        peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.heartRateMeasurement }) else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let data = characteristic.value,
              let measurement = HeartRateMeasurement(data: data) else { return }
        let receivedAt = Date()
        Task { @MainActor in
            self.lastHeartRate = measurement.heartRate
            self.sensorContact = measurement.sensorContact
            if measurement.rrIntervals.isEmpty {
                self.packetsWithoutIntervals += 1
            } else {
                await self.record(intervals: measurement.rrIntervals, receivedAt: receivedAt)
            }
        }
    }
}
