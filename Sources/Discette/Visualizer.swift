import Accelerate
import AppKit
import AudioToolbox
import CoreAudio

/// Live levels from the player's own audio, via a Core Audio process tap (macOS 14.2+).
/// Only Music or Spotify is tapped, nothing is recorded or stored, and it runs only while the
/// visualizer is on and music is playing. macOS asks once for "System Audio Recording" access.
@MainActor
final class Visualizer: ObservableObject {
    static let bandCount = 5

    enum Status: Equatable { case off, running, failed }

    @Published private(set) var levels: [Float] = Array(repeating: 0, count: bandCount)
    @Published private(set) var status: Status = .off

    private var engine: AnyObject?
    private var target: String?

    func update(bundleID: String?, playing: Bool, enabled: Bool) {
        let want = (enabled && playing) ? bundleID : nil
        guard want != target else { return }
        stop()
        target = want
        guard let want else { return }
        guard #available(macOS 14.2, *) else {
            status = .failed
            return
        }
        do {
            engine = try TapEngine(bundlePrefix: want) { [weak self] bands in
                Task { @MainActor in self?.receive(bands) }
            }
            status = .running
        } catch {
            NSLog("Discette: visualizer unavailable: %@", "\(error)")
            status = .failed
        }
    }

    private func receive(_ bands: [Float]) {
        guard status == .running, bands.count == levels.count else { return }
        // Rise fast, fall slowly, like a meter. Rounded to steps the 18 pt bars can show, and
        // published only when something moved, so silence or a steady note redraws nothing.
        let next = zip(levels, bands).map { old, new in
            ((new > old ? new : old * 0.8 + new * 0.2) * 24).rounded() / 24
        }
        if next != levels { levels = next }
    }

    func stop() {
        if #available(macOS 14.2, *) { (engine as? TapEngine)?.stop() }
        engine = nil
        target = nil
        status = .off
        levels = Array(repeating: 0, count: Self.bandCount)
    }
}

enum TapError: Error {
    case noProcess
    case status(String, OSStatus)
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw TapError.status(what, status) }
}

@available(macOS 14.2, *)
final class TapEngine: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.discette.visualizer", qos: .userInteractive)
    private let onBands: ([Float]) -> Void

    private let size = 1024
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var samples: [Float] = []
    private var lastEmit: UInt64 = 0
    private var sampleRate: Double = 48_000

    init(bundlePrefix: String, onBands: @escaping ([Float]) -> Void) throws {
        self.onBands = onBands
        guard let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self) else { throw TapError.noProcess }
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)

        let processes = try Self.processObjects(bundlePrefix: bundlePrefix)
        guard !processes.isEmpty else { throw TapError.noProcess }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Discette visualizer"
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
        tapID = tap

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Discette Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "aggregate device")
        aggregateID = device
        sampleRate = Self.nominalSampleRate(device) ?? 48_000

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }, "io proc")
        procID = proc
        try check(AudioDeviceStart(device, proc), "start")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    // MARK: Audio

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = Int(first.mNumberChannels)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let p = data.assumingMemoryBound(to: Float.self)
        if channels >= 2 {
            // Interleaved stereo: average left and right.
            var i = 0
            while i + 1 < count { samples.append((p[i] + p[i + 1]) * 0.5); i += channels }
        } else if buffers.count >= 2, let second = buffers[1].mData {
            // Non-interleaved stereo.
            let q = second.assumingMemoryBound(to: Float.self)
            for i in 0..<count { samples.append((p[i] + q[i]) * 0.5) }
        } else {
            samples.append(contentsOf: UnsafeBufferPointer(start: p, count: count))
        }
        while samples.count >= size {
            analyze(Array(samples.prefix(size)))
            samples.removeFirst(size / 2) // 50% overlap
        }
    }

    private func analyze(_ frame: [Float]) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastEmit > 50_000_000 else { return } // 20 updates a second is plenty for five bars
        lastEmit = now

        let windowed = vDSP.multiply(frame, window)
        var real = [Float](repeating: 0, count: size / 2)
        var imag = [Float](repeating: 0, count: size / 2)
        var magnitudes = [Float](repeating: 0, count: size / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }
        // Five bands: bass, low mids, mids, presence, air.
        let edges: [Double] = [40, 160, 500, 1_600, 5_000, 14_000]
        let binWidth = sampleRate / Double(size)
        var bands = [Float]()
        for b in 0..<5 {
            let lo = max(1, Int(edges[b] / binWidth))
            let hi = min(size / 2 - 1, max(lo + 1, Int(edges[b + 1] / binWidth)))
            let slice = magnitudes[lo..<hi]
            let mean = slice.reduce(0, +) / Float(slice.count)
            let normalized = mean * 2 / Float(size)
            let db = 20 * log10(max(normalized, 1e-9)) + Float(b) * 3 // lift the quieter highs a little
            bands.append(min(1, max(0, (db + 62) / 50)))
        }
        onBands(bands)
    }

    // MARK: Core Audio lookups

    static func processObjects(bundlePrefix: String) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes), "process list size")
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &ids), "process list")
        return ids.filter { (bundleID(of: $0) ?? "").hasPrefix(bundlePrefix) }
    }

    static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &bytes, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var bytes = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &device),
                  "default output")
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &uid), "output uid")
        guard let value = uid?.takeRetainedValue() as String? else { throw TapError.noProcess }
        return value
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var bytes = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
}
