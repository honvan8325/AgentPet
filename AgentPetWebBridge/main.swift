import Foundation
import Darwin

func readExactly(fd: Int32, count: Int) -> Data? {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let amount = data.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
        }
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { return nil }
        offset += amount
    }
    return data
}

func writeAll(fd: Int32, data: Data) -> Bool {
    var offset = 0
    while offset < data.count {
        let amount = data.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if amount < 0, errno == EINTR { continue }
        guard amount > 0 else { return false }
        offset += amount
    }
    return true
}

func readPacket(fd: Int32) -> Data? {
    guard let header = readExactly(fd: fd, count: 4) else { return nil }
    let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    guard length > 0, length <= 65_536,
          let payload = readExactly(fd: fd, count: Int(length)),
          (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else { return nil }
    return payload
}

func writePacket(fd: Int32, payload: Data) -> Bool {
    guard !payload.isEmpty, payload.count <= 65_536 else { return false }
    var length = UInt32(payload.count).littleEndian
    let header = withUnsafeBytes(of: &length) { Data($0) }
    return writeAll(fd: fd, data: header + payload)
}

func allowedPacket(_ payload: Data, fromChrome: Bool) -> Bool {
    guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let version = value["version"] as? NSNumber,
          String(cString: version.objCType) != "c", version.intValue == 1,
          let type = value["type"] as? String else { return false }
    if fromChrome {
        switch type {
        case "hello", "snapshot", "tab_state", "tab_closed", "generation_ended":
            return true
        case "tab_title":
            guard
                let tabID = value["tabId"] as? NSNumber,
                String(cString: tabID.objCType) != "c",
                tabID.doubleValue >= 0,
                tabID.doubleValue <= Double(Int32.max),
                tabID.doubleValue.rounded() == tabID.doubleValue
            else {
                return false
            }

            let titleValue = value["title"]
            if titleValue == nil || titleValue is NSNull {
                return true
            }
            guard let title = titleValue as? String else { return false }
            return title.utf8.count <= 512
        default:
            return false
        }
    }
    guard type == "open_tab", let tab = value["tabId"] as? NSNumber,
          String(cString: tab.objCType) != "c", tab.doubleValue >= 0,
          tab.doubleValue <= Double(Int32.max), tab.doubleValue.rounded() == tab.doubleValue else { return false }
    return true
}

signal(SIGPIPE, SIG_IGN)
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let registration = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.agentpet.chatgpt.json")
var registrationInfo = stat()
guard CommandLine.arguments.count >= 2,
      lstat(registration.path, &registrationInfo) == 0,
      registrationInfo.st_uid == getuid(),
      (registrationInfo.st_mode & S_IFMT) == S_IFREG,
      (registrationInfo.st_mode & 0o022) == 0,
      let registrationData = try? Data(contentsOf: registration),
      let manifest = try? JSONSerialization.jsonObject(with: registrationData) as? [String: Any],
      manifest["name"] as? String == "com.agentpet.chatgpt",
      let origins = manifest["allowed_origins"] as? [String], origins.count == 1,
      origins[0].range(of: "^chrome-extension://[a-p]{32}/$", options: .regularExpression) != nil,
      CommandLine.arguments[1] == origins[0],
      let executable = manifest["path"] as? String,
      URL(fileURLWithPath: executable).resolvingSymlinksInPath().path ==
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path else {
    exit(EXIT_FAILURE)
}

let socketPath = support.appendingPathComponent("AgentPet/chatgpt-web.sock").path
var socketInfo = stat()
guard lstat(socketPath, &socketInfo) == 0, socketInfo.st_uid == getuid(),
      (socketInfo.st_mode & S_IFMT) == S_IFSOCK else { exit(EXIT_FAILURE) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let pathBytes = Array(socketPath.utf8) + [0]
guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(EXIT_FAILURE) }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard socketFD >= 0 else { exit(EXIT_FAILURE) }
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
var peerUID: uid_t = 0
var peerGID: gid_t = 0
guard connected == 0, getpeereid(socketFD, &peerUID, &peerGID) == 0, peerUID == getuid() else {
    close(socketFD)
    exit(EXIT_FAILURE)
}

DispatchQueue.global(qos: .utility).async {
    while let packet = readPacket(
        fd: STDIN_FILENO
    ) {
        guard allowedPacket(
            packet,
            fromChrome: true
        ) else {
            continue
        }

        guard writePacket(
            fd: socketFD,
            payload: packet
        ) else {
            break
        }
    }
    Darwin.shutdown(socketFD, SHUT_RDWR)
}
while let packet = readPacket(fd: socketFD) {
    guard allowedPacket(packet, fromChrome: false), writePacket(fd: STDOUT_FILENO, payload: packet) else { break }
}
Darwin.shutdown(socketFD, SHUT_RDWR)
close(socketFD)
exit(EXIT_SUCCESS)
