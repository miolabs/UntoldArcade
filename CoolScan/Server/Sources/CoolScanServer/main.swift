import CoolScanServerCore
import Darwin
import Foundation
import MIOServerKit

// CoolScan reconstruction server: receives captures from the iPhone app,
// reconstructs them with Apple photogrammetry at full detail, cooks the
// result to the engine's .untold format and serves it back.
//
//   swift run CoolScanServer [--port 8787] [--jobs-dir DIR] [--detail full|medium|custom]
//                            [--max-upload-mb 64] [--retention-hours 24] [--name NAME]
//                            [--stub-usdz FILE]   (skip photogrammetry; for testing)

struct Arguments {
    var port = 8787
    var jobsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CoolScanServer", isDirectory: true)
    var detail = ReconstructionOptions.Detail.full
    var maxUploadMB = 64
    var retentionHours = 24.0
    var name = Host.current().localizedName ?? "CoolScan Server"
    var stubUSDZ: URL?

    init(_ argv: [String]) {
        var iterator = argv.dropFirst().makeIterator()
        while let flag = iterator.next() {
            func value() -> String { iterator.next() ?? "" }
            switch flag {
            case "--port": port = Int(value()) ?? port
            case "--jobs-dir": jobsDirectory = URL(fileURLWithPath: value(), isDirectory: true)
            case "--detail": detail = ReconstructionOptions.Detail(rawValue: value()) ?? detail
            case "--max-upload-mb": maxUploadMB = Int(value()) ?? maxUploadMB
            case "--retention-hours": retentionHours = Double(value()) ?? retentionHours
            case "--name": name = value()
            case "--stub-usdz": stubUSDZ = URL(fileURLWithPath: value())
            case "-h", "--help":
                print("usage: CoolScanServer [--port N] [--jobs-dir DIR] [--detail full|medium|custom] [--max-upload-mb N] [--retention-hours N] [--name NAME] [--stub-usdz FILE]")
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
                exit(2)
            }
        }
    }
}

/// First non-loopback IPv4 address, preferring Wi-Fi (en0).
func lanIPv4Address() -> String? {
    var addresses: [(name: String, address: String)] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(entry.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        addresses.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
    }
    return (addresses.first { $0.name == "en0" } ?? addresses.first)?.address
}

final class Lifecycle: ServerObserver {
    let name: String
    var advertiser: BonjourAdvertiser?

    init(name: String) { self.name = name }

    func serverDidStart(port: Int) {
        do {
            advertiser = try BonjourAdvertiser(name: name, port: UInt16(port))
            print("Bonjour: advertising \"\(name)\" as \(BonjourAdvertiser.serviceType) on port \(port)")
        } catch {
            print("Bonjour: \(error) — the phone can still connect by address")
        }
        let host = lanIPv4Address() ?? "<this Mac's IP>"
        print("Serving on http://\(host):\(port)  (health: http://\(host):\(port)/health)")
    }
}

signal(SIGPIPE, SIG_IGN)
setlinebuf(stdout) // banner must show even when stdout is a pipe or file

let arguments = Arguments(CommandLine.arguments)
var defaultOptions = ReconstructionOptions()
defaultOptions.detail = arguments.detail

let reconstructor: any Reconstructor = arguments.stubUSDZ.map { StubReconstructor(fixture: $0, tickDelay: .milliseconds(300)) }
    ?? PhotogrammetryReconstructor()

var retention = JobManager.Retention()
retention.maxAge = arguments.retentionHours * 3600

let baseURL = "http://\(lanIPv4Address() ?? "localhost"):\(arguments.port)"
let jobs = try await JobManager(
    rootDirectory: arguments.jobsDirectory,
    reconstructor: reconstructor,
    retention: retention,
    maxUploadBytes: arguments.maxUploadMB * 1024 * 1024,
    serverBaseURL: baseURL
)

print("CoolScan server — jobs in \(arguments.jobsDirectory.path)")
if arguments.stubUSDZ != nil {
    print("Stub mode: photogrammetry is skipped; every job yields \(arguments.stubUSDZ!.lastPathComponent)")
} else if !reconstructor.isSupported {
    print("WARNING: photogrammetry is not supported on this Mac (Apple Silicon or a supported GPU is required)")
}

let router = Routes.makeRouter(jobs: jobs, serverName: arguments.name, defaultOptions: defaultOptions)
let lifecycle = Lifecycle(name: arguments.name)
NIOServer(routes: router, observer: lifecycle).run(port: arguments.port)
