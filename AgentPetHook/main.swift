import Darwin
import Foundation

private let allowedEvents: Set<String> = [
    "UserPromptSubmit",
    "Stop",
    "PermissionRequest",
    "Interrupt"
]

private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let name = payload["hook_event_name"] as? String,
      allowedEvents.contains(name) else {
    exit(EXIT_SUCCESS)
}
let sessionID = payload["session_id"] as? String
let turnID = payload["turn_id"] as? String

let base = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
)[0].appendingPathComponent("AgentPet", isDirectory: true)
let lockURL = base.appendingPathComponent("events.lock")
let logURL = base.appendingPathComponent("events.jsonl")
let gapURL = base.appendingPathComponent("events.gap")

do {
    try FileManager.default.createDirectory(
        at: base,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )

    let lockDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
    guard lockDescriptor >= 0 else { exit(EXIT_SUCCESS) }
    defer { close(lockDescriptor) }
    guard fchmod(lockDescriptor, mode_t(0o600)) == 0 else { exit(EXIT_SUCCESS) }
    guard flock(lockDescriptor, LOCK_EX) == 0 else { exit(EXIT_SUCCESS) }
    defer { flock(lockDescriptor, LOCK_UN) }

    var continuityLost = FileManager.default.fileExists(atPath: gapURL.path)
    let gapDescriptor = Darwin.open(gapURL.path, O_CREAT | O_WRONLY | O_TRUNC, mode_t(0o600))
    guard gapDescriptor >= 0 else { exit(EXIT_SUCCESS) }
    defer { close(gapDescriptor) }
    guard fchmod(gapDescriptor, mode_t(0o600)) == 0,
          writeAll(Data("1".utf8), to: gapDescriptor),
          fsync(gapDescriptor) == 0 else { exit(EXIT_SUCCESS) }

    guard let sessionID, !sessionID.isEmpty, let turnID, !turnID.isEmpty else {
        exit(EXIT_SUCCESS)
    }

    var sequenceBuffer = [UInt8](repeating: 0, count: 32)
    let sequenceLength = sequenceBuffer.withUnsafeMutableBytes { buffer in
        Darwin.pread(lockDescriptor, buffer.baseAddress, buffer.count, 0)
    }
    let previousSequence = sequenceLength > 0
        ? UInt64(String(decoding: sequenceBuffer.prefix(sequenceLength), as: UTF8.self)) ?? 0
        : 0
    let sequence = previousSequence &+ 1
    let sequenceData = Data(String(sequence).utf8)
    guard ftruncate(lockDescriptor, 0) == 0,
          lseek(lockDescriptor, 0, SEEK_SET) >= 0,
          writeAll(sequenceData, to: lockDescriptor) else {
        exit(EXIT_SUCCESS)
    }

    let event: [String: Any] = [
        "event": name,
        "session_id": sessionID,
        "turn_id": turnID,
        "sequence": sequence,
        "timestamp": Date().timeIntervalSince1970
    ]
    var line = try JSONSerialization.data(withJSONObject: event)
    line.append(0x0A)
    guard line.count <= 1_000_000 else { exit(EXIT_SUCCESS) }

    let logDescriptor = Darwin.open(logURL.path, O_CREAT | O_WRONLY | O_APPEND, mode_t(0o600))
    guard logDescriptor >= 0 else { exit(EXIT_SUCCESS) }
    defer { close(logDescriptor) }
    guard fchmod(logDescriptor, mode_t(0o600)) == 0 else { exit(EXIT_SUCCESS) }
    guard flock(logDescriptor, LOCK_EX) == 0 else { exit(EXIT_SUCCESS) }
    defer { flock(logDescriptor, LOCK_UN) }

    var logMetadata = stat()
    guard fstat(logDescriptor, &logMetadata) == 0 else { exit(EXIT_SUCCESS) }
    if logMetadata.st_size + off_t(line.count) > 1_000_000 {
        continuityLost = true
        guard ftruncate(logDescriptor, 0) == 0 else { exit(EXIT_SUCCESS) }
    }
    guard writeAll(line, to: logDescriptor),
          fsync(logDescriptor) == 0,
          fsync(lockDescriptor) == 0 else { exit(EXIT_SUCCESS) }
    if !continuityLost { unlink(gapURL.path) }
} catch {
    exit(EXIT_SUCCESS)
}
