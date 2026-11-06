import Foundation
import Dispatch
import CoreAudio
import AVFoundation
import ProcessTapSpikeCore
import ProcessTapSpikeRing

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw SpikeError("\(operation): OSStatus \(formatOSStatus(status))") }
}

@available(macOS 14.2, *)
enum Hardware {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var result = initial
        var property = address(selector)
        property.mScope = scope
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &result) {
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0),
                      "Read property \(formatOSStatus(Int32(bitPattern: selector))) on \(object)")
        }
        return result
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var result: Unmanaged<CFString>?
        var property = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result), "Read string on \(object)")
        guard let result else { throw SpikeError("Core Audio returned an empty string property on \(object).") }
        return result.takeRetainedValue() as String
    }
    static func processes() throws -> [AudioProcess] {
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size), "Process list size")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if ids.isEmpty { return [] }
        try ids.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!), "Process list")
        }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { id in
            // Processes can exit between enumeration and property reads.
            guard let pid = try? value(id, kAudioProcessPropertyPID, initial: Int32(0)) else { return nil }
            return AudioProcess(objectID: id, pid: pid, bundleID: try? string(id, kAudioProcessPropertyBundleID))
        }
    }
    static func printInputStreams(_ device: AudioObjectID) throws {
        var property = address(kAudioDevicePropertyStreams)
        property.mScope = kAudioObjectPropertyScopeInput
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Aggregate input stream count")
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        if !streams.isEmpty {
            try streams.withUnsafeMutableBytes {
                try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!), "Aggregate input streams")
            }
        }
        print("Aggregate input stream count: \(Int(size) / MemoryLayout<AudioStreamID>.size)")
        for stream in streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.size) {
            let format = try value(stream, kAudioStreamPropertyVirtualFormat,
                                   initial: AudioStreamBasicDescription(), scope: kAudioObjectPropertyScopeInput)
            print("  Input stream \(stream) virtual format: \(format)")
        }
    }
    static func list() throws {
        print("OBJECT ID\tPID\tOUTPUT\tBUNDLE ID")
        for process in try processes() {
            let running = try? value(process.objectID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))
            let output = running.map { $0 == 0 ? "no" : "yes" } ?? "unknown"
            print("\(process.objectID)\t\(process.pid)\t\(output)\t\(process.bundleID ?? "(none)")\(process.isTeams ? "  [Teams]" : "")")
        }
    }
}

@available(macOS 14.2, *)
final class Capture {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var callbackQueue: DispatchQueue?

    // Continue teardown after a failed step and report each failure.
    private func cleanup() {
        func report(_ status: OSStatus, _ operation: String) {
            if status != noErr { fputs("WARNING: \(operation): \(formatOSStatus(status))\n", stderr) }
        }
        if started { report(AudioDeviceStop(device, ioProc), "Stop device"); started = false }
        if let ioProc { report(AudioDeviceDestroyIOProcID(device, ioProc), "Destroy IO proc"); self.ioProc = nil }
        if device != 0 { report(AudioHardwareDestroyAggregateDevice(device), "Destroy aggregate"); device = 0 }
        if tap != 0 { report(AudioHardwareDestroyProcessTap(tap), "Destroy tap"); tap = 0 }
    }
    deinit { cleanup() }

    func run(_ config: Configuration) throws -> Int32 {
        spike_install_interrupt()
        defer { spike_restore_interrupt() }
        defer { cleanup() }
        guard let target = config.target else { throw SpikeError("Missing capture target.") }
        let description: CATapDescription
        if target == .all {
            // PID translation also covers the case where this tool was absent from the initial list.
            var pid = getpid()
            var ownID: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = Hardware.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownID)
            let exclusions: [AudioObjectID]
            if status != noErr || ownID == 0 {
                print("Note: own PID has no Core Audio process object (OSStatus \(formatOSStatus(status)), object \(ownID)); using an empty exclusion list. This is normal when the tool has not produced audio.")
                exclusions = []
            } else { exclusions = [ownID] }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclusions)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: try matchingProcesses(Hardware.processes(), target: target))
        }
        description.name = "Process Tap Spike"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")
        var asbd = try Hardware.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame == 2, asbd.mBytesPerFrame > 0,
              let source = AVAudioFormat(streamDescription: &asbd) else {
            throw SpikeError("Unsupported tap format: \(asbd)")
        }
        print("Tap source format: \(source)")
        let uid = try Hardware.string(tap, kAudioTapPropertyUID)
        let outputDevice = try Hardware.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        let outputUID = try Hardware.string(outputDevice, kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Process Tap Spike",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Create aggregate device")
        if config.verbose {
            print("Tap UID: \(uid)")
            print("Tap kAudioTapPropertyFormat: \(asbd)")
            print("Aggregate device ID: \(device)")
            print("Default output device UID: \(outputUID)")
            // Diagnostic property failures should not prevent the capture itself.
            do {
                print("Default output device name: \(try Hardware.string(outputDevice, kAudioObjectPropertyName))")
            } catch { print("Default output device name unavailable: \(error)") }
            do { try Hardware.printInputStreams(device) }
            catch { print("Aggregate input stream diagnostics unavailable: \(error)") }
        }
        let bufferCount: UInt32 = source.isInterleaved ? 1 : asbd.mChannelsPerFrame
        guard let ring = spike_ring_create(bufferCount, source.isInterleaved ? asbd.mChannelsPerFrame : 1, asbd.mBytesPerFrame) else {
            throw SpikeError("Could not allocate audio ring.")
        }
        // Destroy the IO callback before releasing the ring it references, even on failure.
        defer { cleanup(); spike_ring_destroy(ring) }
        let inputCapacity = AVAudioFrameCount(65536 / asbd.mBytesPerFrame)
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputCapacity),
              let destination = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: destination),
              let converted = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: 4096) else {
            throw SpikeError("Could not create audio converter or buffers.")
        }
        let url = URL(fileURLWithPath: (config.output as NSString).expandingTildeInPath).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { throw SpikeError("Output already exists: \(url.path)") }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: destination.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file = nil }
        var totalMeter = LevelMeter()
        var secondMeter = LevelMeter()
        var framesWritten: Int64 = 0
        func convert(_ buffer: AVAudioPCMBuffer?, finishing: Bool = false) throws {
            var supplied = false
            while true {
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                    if let buffer, !supplied {
                        supplied = true; inputStatus.pointee = .haveData; return buffer
                    }
                    inputStatus.pointee = finishing ? .endOfStream : .noDataNow
                    return nil
                }
                if let error { throw error }
                if status == .error { throw SpikeError("Audio conversion failed without an error detail.") }
                if converted.frameLength > 0 {
                    try file?.write(from: converted)
                    let samples = UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))
                    totalMeter.add(samples); secondMeter.add(samples)
                    framesWritten += Int64(converted.frameLength)
                }
                if status == .inputRanDry || status == .endOfStream { break }
                if converted.frameLength == 0 { throw SpikeError("Audio converter made no progress.") }
            }
        }
        switch config.ioQueue {
        case .dedicated:
            callbackQueue = DispatchQueue(label: "com.markmcchlery.localflow.tapspike.io", qos: .userInteractive)
        case .main: callbackQueue = .main
        case .none: callbackQueue = nil
        }
        print("IO callback queue: \(config.ioQueue.rawValue)")
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, callbackQueue) { _, input, _, _, _ in
            spike_ring_push(ring, input)
        }, "Create IO proc")
        try check(AudioDeviceStart(device, ioProc), "Start aggregate device (check System Audio Recording permission)")
        started = true
        do {
            let running = try Hardware.value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0))
            print("Aggregate kAudioDevicePropertyDeviceIsRunningSomewhere: \(running)")
        } catch {
            print("Aggregate kAudioDevicePropertyDeviceIsRunningSomewhere unavailable: \(error)")
        }
        let start = ProcessInfo.processInfo.systemUptime
        var nextStatus = start + 1
        var checkedFirstSecond = false
        while !spike_interrupted() && ProcessInfo.processInfo.systemUptime - start < config.seconds {
            // Bound each drain so the duration and interrupt checks cannot be starved.
            for _ in 0..<64 {
                let frames = spike_ring_pop(ring, input.mutableAudioBufferList)
                if frames == 0 { break }
                input.frameLength = frames
                try convert(input)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextStatus {
                let levels = secondMeter.levels
                let stats = coreStats(spike_ring_stats(ring))
                if !checkedFirstSecond {
                    checkedFirstSecond = true
                    if stats.callbacks == 0 {
                        print("Hint: No IO callbacks after 1 second; the most likely cause is System Audio Recording permission for the responsible host app (Terminal / Cursor / Claude). Check System Settings > Privacy & Security > Screen & System Audio Recording.")
                    }
                }
                print(String(format: "%.1fs  RMS %.1f dBFS  peak %.1f dBFS  frames %lld", now - start, levels.rmsDBFS, levels.peakDBFS, framesWritten)
                      + "  callbacks \(stats.callbacks)  empty \(stats.empty)  pushed \(stats.pushed)  drops \(stats.drops)")
                secondMeter = LevelMeter()
                nextStatus = now + 1
            }
            if config.ioQueue == .main {
                // Service main-queue callbacks so the A/B option is not starved by this CLI loop.
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        try check(AudioDeviceStop(device, ioProc), "Stop aggregate device")
        started = false
        while true {
            let frames = spike_ring_pop(ring, input.mutableAudioBufferList)
            if frames == 0 { break }
            input.frameLength = frames
            try convert(input)
        }
        try convert(nil, finishing: true)
        file = nil // Close and finalize the CAF before reporting success.
        print("Tap source format: \(source)")
        print(String(format: "Duration written: %.3f seconds (%lld frames)", Double(framesWritten) / 16000, framesWritten))
        print("File: \(url.path)")
        let rawStats = spike_ring_stats(ring)
        let stats = coreStats(rawStats)
        print("Diagnostics:")
        print("  Diagnosis: \(stats.diagnosis(framesWritten: framesWritten).message)")
        print("  callbacks: \(stats.callbacks), empty: \(stats.empty), pushed: \(stats.pushed), drops: \(stats.drops)")
        print("  Drops: ring full \(stats.ringFull), too few buffers \(stats.tooFewBuffers), bad size \(stats.badSize), layout mismatch \(stats.layoutMismatch)")
        if stats.callbacks > 0 {
            printLayout("First callback", rawStats.first)
            printLayout("Latest callback", rawStats.latest)
        } else { print("  Buffer layouts: none observed") }
        if framesWritten == 0 {
            print("ERROR: Zero frames written; finalized empty CAF. Exiting with status 2.")
        } else if totalMeter.levels.wasSilent {
            print("WARNING: Whole capture was silent (peak below -60 dBFS). System Audio Recording permission may be missing: System Settings > Privacy & Security > Screen & System Audio Recording; or nothing was playing.")
        }
        return stats.exitCode(framesWritten: framesWritten)
    }
}

private func coreStats(_ stats: SpikeRingStats) -> CaptureStats {
    CaptureStats(callbacks: stats.callbacks, empty: stats.empty, pushed: stats.pushed,
                 ringFull: stats.ringFull, tooFewBuffers: stats.tooFewBuffers,
                 badSize: stats.badSize, layoutMismatch: stats.layoutMismatch)
}

private func printLayout(_ label: String, _ layout: SpikeBufferLayout) {
    print("  \(label): mNumberBuffers=\(layout.numberBuffers)")
    let channels = [layout.channels.0, layout.channels.1, layout.channels.2, layout.channels.3]
    let bytes = [layout.bytes.0, layout.bytes.1, layout.bytes.2, layout.bytes.3]
    for index in 0..<min(4, Int(layout.numberBuffers)) {
        print("    buffer[\(index)]: mNumberChannels=\(channels[index]), mDataByteSize=\(bytes[index])")
    }
    if layout.numberBuffers > 4 { print("    (layout snapshot limited to first 4 buffers)") }
}
