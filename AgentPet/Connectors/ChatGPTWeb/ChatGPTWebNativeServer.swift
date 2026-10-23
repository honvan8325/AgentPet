import Foundation
import Darwin

final class ChatGPTWebNativeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agentpet.chatgpt.socket", qos: .utility)
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var input = Data()
    private var output = Data()
    private var connectionID: UInt64 = 0
    private var ownedSocket: (dev_t, ino_t)?
    private var onMessage: (@Sendable (UInt64, Data) -> Void)?
    private var onDisconnect: (@Sendable (UInt64) -> Void)?
    private let socketURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentPet/chatgpt-web.sock")

    func start(
        onMessage: @escaping @Sendable (UInt64, Data) -> Void,
        onDisconnect: @escaping @Sendable (UInt64) -> Void
    ) throws {
        try queue.sync {
            stopOnQueue()
            let directory = socketURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var directoryInfo = stat()
            guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
                  (directoryInfo.st_mode & S_IFMT) == S_IFDIR, chmod(directory.path, 0o700) == 0 else {
                throw socketError("AgentPet's support directory must be owned by the current user.")
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = Array(socketURL.path.utf8) + [0]
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw socketError("The ChatGPT socket path is too long.")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
            var existing = stat()
            if lstat(socketURL.path, &existing) == 0 {
                guard existing.st_uid == getuid(), (existing.st_mode & S_IFMT) == S_IFSOCK else {
                    throw socketError("The ChatGPT socket path is occupied by an unexpected file.")
                }
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw socketError("Unable to inspect the ChatGPT socket.") }
                _ = fcntl(probe, F_SETFL, O_NONBLOCK)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                let connectionError = errno
                close(probe)
                guard result != 0, connectionError == ECONNREFUSED else {
                    throw socketError("Another AgentPet instance is using the ChatGPT connector.")
                }
                var current = stat()
                guard lstat(socketURL.path, &current) == 0,
                      current.st_dev == existing.st_dev, current.st_ino == existing.st_ino,
                      unlink(socketURL.path) == 0 else {
                    throw socketError("Unable to remove AgentPet's stale ChatGPT socket.")
                }
            } else if errno != ENOENT {
                throw socketError("Unable to inspect the ChatGPT socket path.")
            }
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw socketError("Unable to create the ChatGPT socket.") }
            _ = fcntl(listener, F_SETFL, O_NONBLOCK)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else {
                close(listener)
                listener = -1
                throw socketError("Unable to bind the ChatGPT socket.")
            }
            var created = stat()
            if lstat(socketURL.path, &created) == 0 { ownedSocket = (created.st_dev, created.st_ino) }
            guard chmod(socketURL.path, 0o600) == 0, Darwin.listen(listener, 4) == 0 else {
                stopOnQueue()
                throw socketError("Unable to listen for the ChatGPT extension.")
            }
            self.onMessage = onMessage
            self.onDisconnect = onDisconnect
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClient() }
            listenerSource = source
            source.resume()
        }
    }

    func stop() { queue.sync { stopOnQueue() } }

    func disconnect() { queue.async { [weak self] in self?.closeClient() } }

    func openTab(_ tabID: Int) {
        queue.async { [weak self] in
            guard let self, client >= 0,
                  let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "type": "open_tab", "tabId": tabID]) else { return }
            var size = UInt32(data.count).littleEndian
            let packet = withUnsafeBytes(of: &size) { Data($0) } + data
            guard output.count + packet.count <= 65_540 else { closeClient(); return }
            output.append(packet)
            flushOutput()
        }
    }

    private func acceptClient() {
        while listener >= 0 {
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard client < 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var noPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            client = fd
            connectionID &+= 1
            let id = connectionID
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, client == fd, connectionID == id else { return }
                readClient()
            }
            clientSource = source
            source.resume()
        }
    }

    private func readClient() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while client >= 0 {
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress!, $0.count) }
            if amount < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                closeClient()
                return
            }
            guard amount > 0 else { closeClient(); return }
            input.append(contentsOf: buffer.prefix(amount))
            while input.count >= 4 {
                let length = input.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                guard length > 0, length <= 65_536 else { closeClient(); return }
                let packetSize = 4 + Int(length)
                guard input.count >= packetSize else { break }
                let payload = Data(input.dropFirst(4).prefix(Int(length)))
                input.removeFirst(packetSize)
                guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else { closeClient(); return }
                onMessage?(connectionID, payload)
            }
        }
    }

    private func flushOutput() {
        while client >= 0, !output.isEmpty {
            let amount = output.withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) }
            if amount < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if writeSource == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: client, queue: queue)
                        source.setEventHandler { [weak self] in self?.flushOutput() }
                        writeSource = source
                        source.resume()
                    }
                    return
                }
                closeClient()
                return
            }
            guard amount > 0 else { closeClient(); return }
            output.removeFirst(amount)
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func closeClient() {
        guard client >= 0 else { return }
        clientSource?.cancel()
        clientSource = nil
        writeSource?.cancel()
        writeSource = nil
        Darwin.shutdown(client, SHUT_RDWR)
        close(client)
        client = -1
        input.removeAll(keepingCapacity: true)
        output.removeAll(keepingCapacity: true)
        onDisconnect?(connectionID)
    }

    private func stopOnQueue() {
        onMessage = nil
        onDisconnect = nil
        closeClient()
        listenerSource?.cancel()
        listenerSource = nil
        if listener >= 0 { close(listener); listener = -1 }
        if let ownedSocket {
            var info = stat()
            if lstat(socketURL.path, &info) == 0, info.st_uid == getuid(),
               (info.st_mode & S_IFMT) == S_IFSOCK,
               info.st_dev == ownedSocket.0, info.st_ino == ownedSocket.1 {
                unlink(socketURL.path)
            }
        }
        ownedSocket = nil
    }

    private func socketError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
