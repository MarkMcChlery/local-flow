import Foundation

public struct SpikeError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ message: String) { description = message }
}

public enum Target: Equatable {
    case bundle(String), pid(Int32), all
}

public enum IOQueueChoice: String, CaseIterable {
    case main, dedicated, none = "nil"
}

public struct Configuration: Equatable {
    public let list: Bool
    public let verbose: Bool
    public let ioQueue: IOQueueChoice
    public let target: Target?
    public let seconds: Double
    public let output: String

    public static let usage = """
    Usage: swift run ProcessTapSpike --list
           swift run ProcessTapSpike (--bundle <id> | --pid <pid> | --all)
                [--seconds N] [--out <path>] [--verbose] [--io-queue <main|dedicated|nil>]
    Captures 16 kHz mono Float32 CAF. Default duration: 10 seconds. Ctrl-C finalizes early.
    """

    public static func parse(_ args: [String], now: Date = Date()) throws -> Configuration {
        var list = false
        var verbose = false
        var ioQueue = IOQueueChoice.dedicated
        var target: Target?
        var seconds = 10.0
        var output = defaultOutputName(date: now)
        var seen = Set<String>()
        var index = 0
        while index < args.count {
            let flag = args[index]
            guard seen.insert(flag).inserted else { throw SpikeError("Repeated option: \(flag)") }
            func value() throws -> String {
                index += 1
                guard index < args.count, !args[index].hasPrefix("--"), !args[index].isEmpty else {
                    throw SpikeError("Missing value for \(flag)")
                }
                return args[index]
            }
            var selected: Target?
            switch flag {
            case "--list": list = true
            case "--verbose": verbose = true
            case "--io-queue":
                guard let choice = IOQueueChoice(rawValue: try value()) else {
                    throw SpikeError("--io-queue must be main, dedicated, or nil.")
                }
                ioQueue = choice
            case "--all": selected = .all
            case "--bundle": selected = .bundle(try value())
            case "--pid":
                guard let pid = Int32(try value()), pid > 0 else { throw SpikeError("PID must be a positive Int32.") }
                selected = .pid(pid)
            case "--seconds":
                guard let number = Double(try value()), number.isFinite, number > 0 else {
                    throw SpikeError("Seconds must be finite and greater than zero.")
                }
                seconds = number
            case "--out":
                output = try value()
                guard (output as NSString).pathExtension.lowercased() == "caf" else {
                    throw SpikeError("Output path must have a .caf extension.")
                }
            default: throw SpikeError("Unknown option: \(flag)")
            }
            if let selected {
                guard target == nil else { throw SpikeError("Choose exactly one capture target.") }
                target = selected
            }
            index += 1
        }
        if list {
            guard seen == ["--list"] else { throw SpikeError("--list must be used alone.") }
        } else if target == nil { throw SpikeError("Missing capture target.") }
        return Configuration(list: list, verbose: verbose, ioQueue: ioQueue, target: target, seconds: seconds, output: output)
    }
}

public struct AudioProcess: Equatable {
    public let objectID: UInt32
    public let pid: Int32
    public let bundleID: String?
    public init(objectID: UInt32, pid: Int32, bundleID: String?) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID
    }
    public var isTeams: Bool { bundleID?.contains("com.microsoft.teams") == true }
}

public func matchingProcesses(_ processes: [AudioProcess], target: Target) throws -> [UInt32] {
    let matches = processes.filter {
        switch target {
        case .all: return true
        case .pid(let pid): return $0.pid == pid
        case .bundle(let id): return !id.isEmpty && ($0.bundleID?.hasPrefix(id) == true)
        }
    }.map(\.objectID)
    guard !matches.isEmpty else { throw SpikeError("No Core Audio processes match \(target). Start the app and play audio, then try --list.") }
    return matches
}

public struct Levels: Equatable {
    public let rmsDBFS: Double
    public let peakDBFS: Double
    public var wasSilent: Bool { peakDBFS < -60 }
}

public struct LevelMeter {
    private var sum = 0.0
    private var peak = 0.0
    private var count = 0
    public init() {}
    public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            let value = sample.isFinite ? Double(sample) : 0
            sum += value * value; peak = max(peak, abs(value)); count += 1
        }
    }
    public var levels: Levels {
        func db(_ value: Double) -> Double { value > 0 ? max(-120, 20 * log10(value)) : -120 }
        return Levels(rmsDBFS: db(count > 0 ? sqrt(sum / Double(count)) : 0), peakDBFS: db(peak))
    }
    public static func measure(_ samples: [Float]) -> Levels {
        var meter = LevelMeter()
        samples.withUnsafeBufferPointer { meter.add($0) }
        return meter.levels
    }
}

public func formatOSStatus(_ status: Int32) -> String {
    let bits = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((bits >> $0) & 0xff) }
    if bytes.allSatisfy({ (32...126).contains($0) }) {
        return "\(status) ('\(String(bytes: bytes, encoding: .ascii)!)')"
    }
    return String(status)
}

public func defaultOutputName(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return "./tap-\(formatter.string(from: date))Z.caf"
}

/// Platform-independent snapshot of the ring's mutually exclusive callback outcomes.
public struct CaptureStats: Equatable {
    public let callbacks, empty, pushed: UInt64
    public let ringFull, tooFewBuffers, badSize, layoutMismatch: UInt64
    public init(callbacks: UInt64 = 0, empty: UInt64 = 0, pushed: UInt64 = 0,
                ringFull: UInt64 = 0, tooFewBuffers: UInt64 = 0,
                badSize: UInt64 = 0, layoutMismatch: UInt64 = 0) {
        self.callbacks = callbacks; self.empty = empty; self.pushed = pushed
        self.ringFull = ringFull; self.tooFewBuffers = tooFewBuffers
        self.badSize = badSize; self.layoutMismatch = layoutMismatch
    }
    public var drops: UInt64 { ringFull + tooFewBuffers + badSize + layoutMismatch }
    public func diagnosis(framesWritten: Int64) -> CaptureDiagnosis {
        if callbacks == 0 { return .neverRan }
        if empty == callbacks { return .allEmpty }
        if drops > 0 { return .dropped }
        if framesWritten == 0 { return .noConvertedFrames }
        return .ok
    }
    public func exitCode(framesWritten: Int64) -> Int32 {
        if framesWritten == 0 { return 2 }
        return drops > 0 ? 1 : 0
    }
}

public enum CaptureDiagnosis: Equatable {
    case neverRan, allEmpty, dropped, noConvertedFrames, ok
    public var message: String {
        switch self {
        case .neverRan:
            return "IO proc never ran. Check that the aggregate device started and its output device is available."
        case .allEmpty:
            return "Every callback had empty (0-byte) tap buffers. This usually means System Audio Recording permission is not granted to the responsible app (the terminal). Check System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch the terminal if needed."
        case .dropped:
            return "Input blocks were dropped. See ring full, too few buffers, bad size, and layout mismatch counts below; the capture is incomplete."
        case .noConvertedFrames:
            return "The IO proc supplied input blocks, but the converter wrote zero frames. Check the tap and aggregate stream formats with --verbose."
        case .ok:
            return "Audio frames were written with no dropped input blocks."
        }
    }
}
