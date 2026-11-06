import XCTest
@testable import ProcessTapSpikeCore

final class ProcessTapSpikeTests: XCTestCase {
    func testDefaultsAndAll() throws {
        let config = try Configuration.parse(["--all"], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(config.target, .all)
        XCTAssertFalse(config.list)
        XCTAssertEqual(config.seconds, 10)
        XCTAssertEqual(config.output, "./tap-19700101-000000-000Z.caf")
    }
    func testArguments() throws {
        let config = try Configuration.parse(["--out", "a path.caf", "--seconds", "0.25", "--bundle", "com.microsoft.teams"])
        XCTAssertEqual(config.target, .bundle("com.microsoft.teams"))
        XCTAssertEqual(config.seconds, 0.25)
        XCTAssertEqual(config.output, "a path.caf")
        XCTAssertEqual(try Configuration.parse(["--pid", "2147483647"]).target, .pid(Int32.max))
        XCTAssertTrue(try Configuration.parse(["--list"]).list)
        XCTAssertEqual(try Configuration.parse(["--all", "--out", "A.CAF"]).output, "A.CAF")
    }
    func testVerboseFlag() throws {
        XCTAssertFalse(try Configuration.parse(["--all"]).verbose)
        XCTAssertTrue(try Configuration.parse(["--all", "--verbose"]).verbose)
        XCTAssertTrue(try Configuration.parse(["--verbose", "--pid", "5"]).verbose)
        XCTAssertEqual(try Configuration.parse(["--verbose", "--pid", "5"]).target, .pid(5))
        XCTAssertThrowsError(try Configuration.parse(["--verbose"]))
        XCTAssertThrowsError(try Configuration.parse(["--all", "--verbose", "--verbose"]))
        XCTAssertThrowsError(try Configuration.parse(["--list", "--verbose"]))
    }
    func testIOQueueChoices() throws {
        XCTAssertEqual(try Configuration.parse(["--all"]).ioQueue, .dedicated)
        for choice in IOQueueChoice.allCases {
            let config = try Configuration.parse(["--io-queue", choice.rawValue, "--all", "--verbose"])
            XCTAssertEqual(config.ioQueue, choice)
            XCTAssertTrue(config.verbose)
        }
    }
    func testInvalidIOQueueChoices() {
        for args in [
            ["--all", "--io-queue"], ["--all", "--io-queue", ""],
            ["--all", "--io-queue", "background"], ["--all", "--io-queue", "MAIN"],
            ["--all", "--io-queue", "--verbose"],
            ["--all", "--io-queue", "nil", "--io-queue", "main"],
            ["--list", "--io-queue", "main"], ["--io-queue", "dedicated"]
        ] {
            XCTAssertThrowsError(try Configuration.parse(args), "\(args)")
        }
    }
    func testInvalidArguments() {
        let invalid: [[String]] = [[], ["--wat"], ["--all", "--pid", "1"], ["--bundle", "x", "--all"],
            ["--all", "--all"], ["--list", "--all"], ["--list", "--out", "x"], ["--list", "--list"],
            ["--pid"], ["--pid", "0"], ["--pid", "-1"], ["--pid", "1.5"], ["--pid", "x"],
            ["--pid", "2147483648"], ["--bundle"], ["--bundle", ""], ["--bundle", "--all"],
            ["--all", "--out", "audio.wav"], ["--all", "--out", "audio"], ["--all", "--out"], ["--all", "--out", ""], ["--seconds", "2"],
            ["--all", "--seconds"], ["--all", "--seconds", "1", "--seconds", "2"]]
        for args in invalid { XCTAssertThrowsError(try Configuration.parse(args), "\(args)") }
        for number in ["0", "-0", "-10", "NaN", "inf", "-inf", "1e999", "hello"] {
            XCTAssertThrowsError(try Configuration.parse(["--all", "--seconds", number]))
        }
    }
    let processes = [AudioProcess(objectID: 1, pid: 10, bundleID: "com.microsoft.teams"),
                     AudioProcess(objectID: 2, pid: 11, bundleID: "com.microsoft.teams.helper"),
                     AudioProcess(objectID: 3, pid: 10, bundleID: nil),
                     AudioProcess(objectID: 4, pid: 12, bundleID: "org.example.app")]
    func testProcessMatching() throws {
        XCTAssertEqual(try matchingProcesses(processes, target: .bundle("com.microsoft.teams")), [1, 2])
        XCTAssertEqual(try matchingProcesses(processes, target: .bundle("com.microsoft.teams.helper")), [2])
        XCTAssertEqual(try matchingProcesses(processes, target: .pid(10)), [1, 3])
        XCTAssertEqual(try matchingProcesses(processes, target: .all), [1, 2, 3, 4])
        XCTAssertTrue(processes[0].isTeams)
        XCTAssertTrue(processes[1].isTeams)
        XCTAssertFalse(processes[2].isTeams)
        XCTAssertFalse(processes[3].isTeams)
        for target in [Target.pid(99), .bundle("missing"), .bundle(""), .bundle("COM.microsoft.teams")] {
            XCTAssertThrowsError(try matchingProcesses(processes, target: target)) { error in
                XCTAssertTrue(String(describing: error).contains("No Core Audio processes match"))
            }
        }
        XCTAssertThrowsError(try matchingProcesses([], target: .all))
    }
    func testMeterSilenceAndEmpty() {
        for samples: [Float] in [[], [0, 0], [Float.nan, .infinity, -.infinity]] {
            let levels = LevelMeter.measure(samples)
            XCTAssertEqual(levels.rmsDBFS, -120)
            XCTAssertEqual(levels.peakDBFS, -120)
            XCTAssertTrue(levels.wasSilent)
        }
        XCTAssertTrue(LevelMeter.measure([0.0001]).wasSilent)
        XCTAssertFalse(LevelMeter.measure([0.001]).wasSilent)
    }
    func testMeterLevelsAndIncrementalBlocks() {
        let levels = LevelMeter.measure([1, -1, 0, 0])
        XCTAssertEqual(levels.peakDBFS, 0)
        XCTAssertEqual(levels.rmsDBFS, -3.0102999566, accuracy: 0.000001)
        XCTAssertFalse(levels.wasSilent)
        XCTAssertEqual(LevelMeter.measure([-0.5, 0.5]).peakDBFS, -6.020599913, accuracy: 0.000001)
        XCTAssertEqual(LevelMeter.measure([2]).peakDBFS, 6.020599913, accuracy: 0.000001)
        XCTAssertEqual(LevelMeter.measure([1e-20]).peakDBFS, -120)
        var meter = LevelMeter()
        [Float(1), -1].withUnsafeBufferPointer { meter.add($0) }
        [Float(0), 0].withUnsafeBufferPointer { meter.add($0) }
        XCTAssertEqual(meter.levels, levels)
    }
    func testStatusFormatting() {
        XCTAssertEqual(formatOSStatus(0x666D743F), "1718449215 ('fmt?')")
        XCTAssertEqual(formatOSStatus(0x20202020), "538976288 ('    ')")
        XCTAssertEqual(formatOSStatus(0), "0")
        XCTAssertEqual(formatOSStatus(-1), "-1")
        XCTAssertEqual(formatOSStatus(0x7F616263), String(0x7F616263))
        XCTAssertEqual(formatOSStatus(0x1F616263), String(0x1F616263))
    }
    func testDateNaming() {
        XCTAssertEqual(defaultOutputName(date: Date(timeIntervalSince1970: 0)), "./tap-19700101-000000-000Z.caf")
        XCTAssertEqual(defaultOutputName(date: Date(timeIntervalSince1970: 86400.125)), "./tap-19700102-000000-125Z.caf")
        XCTAssertEqual(defaultOutputName(date: Date(timeIntervalSince1970: -1)), "./tap-19691231-235959-000Z.caf")
    }
    func testCaptureStatsDefaultsAndDrops() {
        let zero = CaptureStats()
        XCTAssertEqual(zero, CaptureStats(callbacks: 0, empty: 0, pushed: 0, ringFull: 0,
                                          tooFewBuffers: 0, badSize: 0, layoutMismatch: 0))
        XCTAssertEqual(zero.drops, 0)
        XCTAssertEqual(CaptureStats(ringFull: 1).drops, 1)
        XCTAssertEqual(CaptureStats(tooFewBuffers: 2).drops, 2)
        XCTAssertEqual(CaptureStats(badSize: 3).drops, 3)
        XCTAssertEqual(CaptureStats(layoutMismatch: 4).drops, 4)
        XCTAssertEqual(CaptureStats(callbacks: 99, empty: 5, pushed: 50, ringFull: 1, tooFewBuffers: 2,
                                    badSize: 3, layoutMismatch: 4).drops, 10)
    }
    func testDiagnosisNeverRan() {
        XCTAssertEqual(CaptureStats().diagnosis(framesWritten: 0), .neverRan)
        // neverRan wins even if frames were somehow written.
        XCTAssertEqual(CaptureStats().diagnosis(framesWritten: 100), .neverRan)
        XCTAssertEqual(CaptureStats(ringFull: 1).diagnosis(framesWritten: 0), .neverRan)
        XCTAssertTrue(CaptureDiagnosis.neverRan.message.contains("IO proc never ran"))
    }
    func testDiagnosisAllEmpty() {
        XCTAssertEqual(CaptureStats(callbacks: 10, empty: 10).diagnosis(framesWritten: 0), .allEmpty)
        XCTAssertEqual(CaptureStats(callbacks: 1, empty: 1).diagnosis(framesWritten: 0), .allEmpty)
        // allEmpty takes priority over drops.
        XCTAssertEqual(CaptureStats(callbacks: 10, empty: 10, ringFull: 3).diagnosis(framesWritten: 0), .allEmpty)
        // One non-empty callback is not allEmpty.
        XCTAssertNotEqual(CaptureStats(callbacks: 10, empty: 9, pushed: 1).diagnosis(framesWritten: 160), .allEmpty)
        XCTAssertTrue(CaptureDiagnosis.allEmpty.message.contains("System Audio Recording permission"))
    }
    func testDiagnosisDropped() {
        for stats in [CaptureStats(callbacks: 10, pushed: 9, ringFull: 1),
                      CaptureStats(callbacks: 10, pushed: 9, tooFewBuffers: 1),
                      CaptureStats(callbacks: 10, pushed: 9, badSize: 1),
                      CaptureStats(callbacks: 10, pushed: 9, layoutMismatch: 1),
                      CaptureStats(callbacks: 10, empty: 5, pushed: 4, ringFull: 1)] {
            XCTAssertEqual(stats.diagnosis(framesWritten: 1000), .dropped, "\(stats)")
            // dropped takes priority over zero converted frames.
            XCTAssertEqual(stats.diagnosis(framesWritten: 0), .dropped, "\(stats)")
        }
        XCTAssertTrue(CaptureDiagnosis.dropped.message.contains("dropped"))
    }
    func testDiagnosisNoConvertedFramesAndOK() {
        let stats = CaptureStats(callbacks: 10, empty: 2, pushed: 8)
        XCTAssertEqual(stats.diagnosis(framesWritten: 0), .noConvertedFrames)
        XCTAssertEqual(stats.diagnosis(framesWritten: 1), .ok)
        XCTAssertEqual(stats.diagnosis(framesWritten: 16000), .ok)
        XCTAssertTrue(CaptureDiagnosis.noConvertedFrames.message.contains("converter wrote zero frames"))
        XCTAssertTrue(CaptureDiagnosis.ok.message.contains("no dropped input blocks"))
    }
    func testDiagnosisMessagesAreDistinctAndNonEmpty() {
        let all: [CaptureDiagnosis] = [.neverRan, .allEmpty, .dropped, .noConvertedFrames, .ok]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
        for diagnosis in all { XCTAssertFalse(diagnosis.message.isEmpty) }
    }
    func testExitCodes() {
        // Zero frames written always exits 2, regardless of other stats.
        for stats in [CaptureStats(), CaptureStats(callbacks: 10, empty: 10),
                      CaptureStats(callbacks: 10, pushed: 8, ringFull: 2),
                      CaptureStats(callbacks: 10, pushed: 10)] {
            XCTAssertEqual(stats.exitCode(framesWritten: 0), 2, "\(stats)")
        }
        // Frames written with drops exits 1.
        XCTAssertEqual(CaptureStats(callbacks: 10, pushed: 9, ringFull: 1).exitCode(framesWritten: 100), 1)
        XCTAssertEqual(CaptureStats(callbacks: 10, pushed: 9, layoutMismatch: 1).exitCode(framesWritten: 1), 1)
        // Frames written and no drops exits 0.
        XCTAssertEqual(CaptureStats(callbacks: 10, pushed: 10).exitCode(framesWritten: 1), 0)
        XCTAssertEqual(CaptureStats(callbacks: 10, empty: 3, pushed: 7).exitCode(framesWritten: 16000), 0)
    }
}
