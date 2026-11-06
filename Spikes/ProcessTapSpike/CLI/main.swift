import Foundation
import ProcessTapSpikeCore

if CommandLine.arguments.dropFirst().contains("--help") {
    print(Configuration.usage)
    exit(0)
}
do {
    let config = try Configuration.parse(Array(CommandLine.arguments.dropFirst()))
    guard #available(macOS 14.2, *) else { throw SpikeError("ProcessTapSpike requires macOS 14.2 or later for Core Audio process taps.") }
    if config.list { try Hardware.list() } else {
        let status = try Capture().run(config) // Return first so all cleanup defers execute.
        exit(status)
    }
} catch {
    fputs("Error: \(error)\n\n\(Configuration.usage)\n", stderr)
    exit(1)
}
