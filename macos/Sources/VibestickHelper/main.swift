import Foundation
import VibestickMacCore

struct HelperEnvelope<T: Encodable>: Encodable {
    let ok: Bool
    let value: T?
    let error: String?
}

let arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")
let command = arguments.first { !$0.hasPrefix("-") } ?? "help"
let manager = PmsetPowerPolicyManager()

func writeJSON<T: Encodable>(_ value: T) {
    let data = try! VibestickJSON.encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func writeText(_ value: String) {
    print(value)
}

func run() throws {
    switch command {
    case "status":
        let status = HelperStatus(
            ok: true,
            snapshot: try manager.readSnapshot(),
            backup: try manager.readBackup(),
            statePath: manager.statePath.path)
        if json {
            writeJSON(status)
        } else {
            writeText("Vibestick helper OK")
        }

    case "apply-on":
        let result = try manager.applyOn()
        json ? writeJSON(result) : writeText(result.message)

    case "apply-hyper":
        let result = try manager.applyHyper()
        json ? writeJSON(result) : writeText(result.message)

    case "restore":
        let result = try manager.restore()
        json ? writeJSON(result) : writeText(result.message)

    case "daemon":
        signal(SIGTERM) { _ in exit(0) }
        while true {
            Thread.sleep(forTimeInterval: 3600)
        }

    case "help", "--help", "-h":
        writeText("""
        VibestickHelper
        Usage:
          VibestickHelper [--json] status
          VibestickHelper [--json] apply-on
          VibestickHelper [--json] apply-hyper
          VibestickHelper [--json] restore
          VibestickHelper daemon
        """)

    default:
        throw ValidationError("Unknown helper command '\(command)'.")
    }
}

do {
    try run()
} catch {
    if json {
        writeJSON(HelperStatus(
            ok: false,
            snapshot: nil,
            backup: nil,
            statePath: manager.statePath.path,
            message: error.localizedDescription))
    } else {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    }
    exit(3)
}

struct ValidationError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
