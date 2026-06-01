// VideoStream.swift — raw H.264/H.265 Annex-B stream reader for :8080.
//
// HTTP handshake by hand over NWConnection (URLSession.bytes buffers
// chunkless infinite responses on iOS 17/18). Body bytes go through a
// CHUNK-based Annex-B splitter (not byte-by-byte — that was pegging a
// core at 15 Mbps) and each complete NAL is delivered via a SYNCHRONOUS
// callback. Synchronous on purpose: the old async callback created an
// actor-await chain (VideoStream → session → recorder) that tangled with
// stop() and hung. Now the producer task calls one plain closure; the
// closure does its own (lock-based) synchronization.

import Foundation
import Network

public final class VideoStream: @unchecked Sendable {
    public struct NALUnit: Sendable {
        public let codec: VideoCodec
        /// NAL payload WITHOUT the start code.
        public let payload: Data
        public var firstByte: UInt8 { payload.first ?? 0 }
        public let hostReceivedNs: UInt64
        /// Device capture timing parsed from the TRINETVSYNC SEI that preceded
        /// this VCL in the same access unit (nil for param-set NALs or streams
        /// without the SEI). Set by TrinetLiveSession.onNAL.
        public var timing: FrameTiming? = nil
    }

    /// Synchronous — called from the single receive task, in stream order.
    public typealias NALCallback = @Sendable (NALUnit) -> Void

    public let host: String
    public let port: UInt16
    public let codec: VideoCodec
    public let interfaceName: String?     // USB interface to pin to (e.g. "en5")

    private let lock = NSLock()
    private var connection: NWConnection?
    private var onNAL: NALCallback?
    private var splitter = AnnexBSplitter()
    private var headerDone = false
    private var headerBuffer = Data()
    private var stopped = false
    private var receiveStarted = false

    public init(host: String, port: UInt16 = 8080, codec: VideoCodec,
                interfaceName: String? = nil) {
        self.host = host
        self.port = port
        self.codec = codec
        self.interfaceName = interfaceName
    }

    public func start(onNAL: @escaping NALCallback) {
        lock.lock()
        guard connection == nil, !stopped else { lock.unlock(); return }
        self.onNAL = onNAL
        lock.unlock()

        // Build the pinned parameters + connection OFF the caller thread.
        // InterfacePinning waits briefly on an NWPathMonitor to resolve the USB
        // interface; doing that on the main thread froze the Record screen on
        // first open (the "had to go to Library and back" hang).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let params = InterfacePinning.tcp(boundTo: self.interfaceName)
            let conn = NWConnection(host: .init(self.host),
                                    port: .init(rawValue: self.port)!, using: params)
            self.lock.lock()
            if self.stopped { self.lock.unlock(); conn.cancel(); return }
            self.connection = conn
            self.lock.unlock()

            conn.stateUpdateHandler = { [weak self] state in self?.onState(state) }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        receiveStarted = false
        let conn = connection
        connection = nil
        onNAL = nil
        splitter = AnnexBSplitter()
        headerBuffer.removeAll()
        headerDone = false
        lock.unlock()
        conn?.cancel()
    }

    // MARK: - Connection lifecycle

    private func onState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            lock.lock()
            let go = !receiveStarted && !stopped
            if go { receiveStarted = true }
            let conn = connection
            lock.unlock()
            guard go, let conn else { return }
            sendHTTPRequest(on: conn)
            receiveLoop(on: conn)
        case .failed, .cancelled:
            break
        default:
            break
        }
    }

    private func sendHTTPRequest(on conn: NWConnection) {
        let suffix = (codec == .h265) ? "h265" : "h264"
        let req =
            "GET /live.\(suffix) HTTP/1.1\r\n" +
            "Host: \(host):\(port)\r\n" +
            "User-Agent: TrinetSDK-iOS/0.1\r\n" +
            "Accept: */*\r\n" +
            "Connection: close\r\n\r\n"
        conn.send(content: req.data(using: .ascii)!,
                  completion: .contentProcessed { _ in })
    }

    /// Callback-driven receive loop — no Task/await. Each receive
    /// completion handler schedules the next receive. Runs on the
    /// connection's dispatch queue (a single serial queue), so the
    /// splitter + callback are effectively single-threaded.
    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            self.lock.lock()
            let stop = self.stopped
            self.lock.unlock()
            if error != nil || isComplete || stop { return }
            self.receiveLoop(on: conn)
        }
    }

    private func consume(_ chunk: Data) {
        // Strip HTTP headers on the first chunk(s).
        var body: Data
        lock.lock()
        if headerDone {
            lock.unlock()
            body = chunk
        } else {
            headerBuffer.append(chunk)
            if let range = headerBuffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                body = headerBuffer.subdata(in: range.upperBound..<headerBuffer.count)
                headerBuffer.removeAll()
                headerDone = true
                lock.unlock()
            } else {
                lock.unlock()
                return   // still buffering headers
            }
        }

        // Parse + deliver NALs. Snapshot the callback under lock; call it
        // outside the lock (the callback synchronizes itself).
        lock.lock()
        let cb = onNAL
        lock.unlock()
        guard let cb else { return }

        splitter.push(body) { [codec] payload in
            let unit = NALUnit(codec: codec,
                               payload: payload,
                               hostReceivedNs: SyncCoordinator.monotonicNs())
            cb(unit)
        }
    }
}

/// Chunk-based Annex-B splitter. Accumulates a small tail buffer (one
/// in-flight NAL) and, per chunk, scans for start codes and emits each
/// complete NAL between consecutive start codes. No per-byte Data.append.
struct AnnexBSplitter {
    private var buf = Data()

    mutating func push(_ chunk: Data, emit: (Data) -> Void) {
        buf.append(chunk)
        let n = buf.count
        guard n >= 4 else { return }

        // Find all start-code positions (3- or 4-byte).
        var starts: [(idx: Int, len: Int)] = []
        buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = 0
            while i + 3 <= n {
                if p[i] == 0 && p[i + 1] == 0 {
                    if p[i + 2] == 1 {
                        starts.append((i, 3)); i += 3; continue
                    } else if i + 4 <= n && p[i + 2] == 0 && p[i + 3] == 1 {
                        starts.append((i, 4)); i += 4; continue
                    }
                }
                i += 1
            }
        }
        guard !starts.isEmpty else { return }

        // Emit each NAL between consecutive start codes.
        for k in 0..<(starts.count - 1) {
            let nalStart = starts[k].idx + starts[k].len
            let nalEnd   = starts[k + 1].idx
            if nalEnd > nalStart {
                emit(buf.subdata(in: nalStart..<nalEnd))
            }
        }

        // Retain the tail from the last (incomplete) start code onward.
        let lastIdx = starts[starts.count - 1].idx
        if lastIdx > 0 {
            buf.removeSubrange(0..<lastIdx)
        }
        // Safety cap: a NAL should never exceed a few MB. If the tail grows
        // pathologically (no start code for ages), drop it to avoid OOM.
        if buf.count > 8 * 1024 * 1024 {
            buf.removeAll(keepingCapacity: false)
        }
    }
}
