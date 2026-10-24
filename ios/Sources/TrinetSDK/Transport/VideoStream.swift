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
        /// Device capture timing derived from the Trinet IMU SEI that preceded
        /// this VCL in the same access unit (nil for param-set NALs or streams
        /// without the SEI). Set by TrinetLiveSession.onNAL.
        public var timing: FrameTiming? = nil
    }

    /// Synchronous — called from the single receive task, in stream order.
    public typealias NALCallback = @Sendable (NALUnit) -> Void

    public let host: String
    public let port: UInt16
    /// The codec the caller expects (e.g. from `TrinetDevice.streamCodec()`).
    /// The server ignores the URL suffix and streams whatever it is configured
    /// for, so the HTTP `Content-Type` is authoritative: see `activeCodec`.
    public let codec: VideoCodec
    public let interfaceName: String?     // USB interface to pin to (e.g. "en5")
    /// How long to keep retrying the initial connection (refused, reset, or a
    /// non-200 answer) before giving up — covers the camera restarting its
    /// stream, e.g. right after a stream-codec change. 0 = single attempt.
    public let connectRetryWindow: TimeInterval

    private let lock = NSLock()
    /// Every NWConnection callback (state + receive) and ALL parsing state
    /// (`splitter`, `headerBuffer`, `headerDone`) live on this one serial
    /// queue. stop() and the retry path reset that state ON this queue, so a
    /// chunk is never parsed while the splitter is being replaced. (Callbacks
    /// used to run on a global concurrent queue while stop() swapped the
    /// splitter from the main thread — a data race that trapped inside
    /// Data.removeSubrange when switching screens.)
    private let ioQueue = DispatchQueue(label: "com.panoculon.trinet.videostream",
                                        qos: .userInitiated)
    private var connection: NWConnection?
    private var onNAL: NALCallback?
    private var splitter = AnnexBSplitter()     // ioQueue only
    private var headerDone = false              // written on ioQueue; read under lock
    private var headerBuffer = Data()           // ioQueue only
    private var stopped = false
    private var receiveStarted = false
    private var retryDeadline = Date.distantPast
    private var _activeCodec: VideoCodec

    /// The codec actually being delivered: the HTTP response's `Content-Type`
    /// (video/H264 | video/H265) once the headers arrive, else `codec`. Every
    /// `NALUnit` is stamped with this value.
    public var activeCodec: VideoCodec {
        lock.lock(); defer { lock.unlock() }
        return _activeCodec
    }

    public init(host: String, port: UInt16 = 8080, codec: VideoCodec,
                interfaceName: String? = nil, connectRetryWindow: TimeInterval = 20) {
        self.host = host
        self.port = port
        self.codec = codec
        self._activeCodec = codec
        self.interfaceName = interfaceName
        self.connectRetryWindow = max(0, connectRetryWindow)
    }

    public func start(onNAL: @escaping NALCallback) {
        lock.lock()
        guard connection == nil, !stopped else { lock.unlock(); return }
        self.onNAL = onNAL
        self.retryDeadline = Date().addingTimeInterval(connectRetryWindow)
        lock.unlock()
        connect()
    }

    /// Build the pinned parameters + connection OFF the caller thread.
    /// InterfacePinning waits briefly on an NWPathMonitor to resolve the USB
    /// interface; doing that on the main thread froze the Record screen on
    /// first open (the "had to go to Library and back" hang).
    private func connect() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let params = InterfacePinning.tcp(boundTo: self.interfaceName)
            let conn = NWConnection(host: .init(self.host),
                                    port: .init(rawValue: self.port)!, using: params)
            self.lock.lock()
            if self.stopped || self.connection != nil { self.lock.unlock(); conn.cancel(); return }
            self.connection = conn
            self.lock.unlock()

            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self, let conn else { return }
                self.onState(state, conn)
            }
            conn.start(queue: self.ioQueue)
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        receiveStarted = false
        let conn = connection
        connection = nil
        onNAL = nil
        lock.unlock()
        conn?.cancel()
        // Parsing state belongs to ioQueue: reset it there, after any chunk
        // already being parsed has finished (later ones see `connection` nil
        // and are dropped).
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.splitter = AnnexBSplitter()
            self.headerBuffer.removeAll()
            self.lock.lock(); self.headerDone = false; self.lock.unlock()
        }
    }

    // MARK: - Connection lifecycle

    private func onState(_ state: NWConnection.State, _ conn: NWConnection) {
        switch state {
        case .ready:
            lock.lock()
            let go = !receiveStarted && !stopped && conn === connection
            if go { receiveStarted = true }
            lock.unlock()
            guard go else { return }
            sendHTTPRequest(on: conn)
            receiveLoop(on: conn)
        case .waiting, .failed:
            // .waiting = e.g. connection refused while the camera's stream
            // server restarts; Network.framework would only retry on a path
            // change, so retry on our own schedule.
            retryIfStillConnecting(conn)
        default:
            break
        }
    }

    /// If `conn` is the current connection and the stream never got going,
    /// tear it down and try again in 1 s — until `retryDeadline`. Runs on
    /// ioQueue (connection state handler / receive completion).
    private func retryIfStillConnecting(_ conn: NWConnection) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        lock.lock()
        guard conn === connection, !stopped, !headerDone else { lock.unlock(); return }
        connection = nil
        receiveStarted = false
        let retry = Date() < retryDeadline
        lock.unlock()
        headerBuffer.removeAll()
        splitter = AnnexBSplitter()
        conn.cancel()
        guard retry else {
            NSLog("TrinetSDK VideoStream: :\(port) unreachable — giving up")
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.connect()
        }
    }

    /// Codec named by an HTTP response header block's `Content-Type`
    /// (`video/H264` / `video/H265`, case-insensitive; HEVC/AVC also accepted).
    /// nil if absent or not a video codec we know.
    static func codec(fromHTTPHeader header: String) -> VideoCodec? {
        // "\r\n" is ONE Character (grapheme) in Swift, so split on isNewline —
        // comparing against "\r" / "\n" never matches a CRLF line break.
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-type"
            else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if v.contains("h265") || v.contains("hevc") { return .h265 }
            if v.contains("h264") || v.contains("avc") { return .h264 }
            return nil
        }
        return nil
    }

    /// HTTP status code from the response's status line, or nil.
    static func statusCode(fromHTTPHeader header: String) -> Int? {
        guard let first = header.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
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
            self.lock.lock()
            let current = (conn === self.connection)
            self.lock.unlock()
            guard current else { return }   // superseded by a retry
            var ok = true
            if let data, !data.isEmpty {
                ok = self.consume(data)
            }
            self.lock.lock()
            let stop = self.stopped
            let streaming = self.headerDone
            self.lock.unlock()
            if !ok || ((error != nil || isComplete) && !streaming) {
                // Rejected / closed before the stream started (camera still
                // restarting its stream server) — retry within the window.
                self.retryIfStillConnecting(conn)
                return
            }
            if error != nil || isComplete || stop { return }
            self.receiveLoop(on: conn)
        }
    }

    /// Returns false if the response was not a 200 (caller retries).
    /// Runs on ioQueue only.
    private func consume(_ chunk: Data) -> Bool {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        // Strip HTTP headers on the first chunk(s).
        var body: Data
        lock.lock()
        if headerDone {
            lock.unlock()
            body = chunk
        } else {
            headerBuffer.append(chunk)
            if let range = headerBuffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let header = String(decoding: headerBuffer.subdata(in: 0..<range.lowerBound),
                                    as: UTF8.self)
                if let status = Self.statusCode(fromHTTPHeader: header), status != 200 {
                    lock.unlock()
                    NSLog("TrinetSDK VideoStream: HTTP \(status) from :\(port)")
                    return false
                }
                // The server streams whatever codec the camera is configured
                // for; Content-Type is the truth. NAL parsing, the decoder and
                // the MP4 writer all key off the NALUnit's codec.
                if let ct = Self.codec(fromHTTPHeader: header), ct != _activeCodec {
                    NSLog("TrinetSDK VideoStream: expected \(_activeCodec.rawValue), server sends \(ct.rawValue) — using \(ct.rawValue)")
                    _activeCodec = ct
                }
                body = headerBuffer.subdata(in: range.upperBound..<headerBuffer.count)
                headerBuffer.removeAll()
                headerDone = true
                lock.unlock()
            } else {
                // Guard against a peer that never ends its headers.
                if headerBuffer.count > 64 * 1024 { headerBuffer.removeAll(); lock.unlock(); return false }
                lock.unlock()
                return true   // still buffering headers
            }
        }

        // Parse + deliver NALs. Snapshot the callback under lock; call it
        // outside the lock (the callback synchronizes itself).
        lock.lock()
        let cb = onNAL
        let codec = _activeCodec
        lock.unlock()
        guard let cb else { return true }

        splitter.push(body) { payload in
            let unit = NALUnit(codec: codec,
                               payload: payload,
                               hostReceivedNs: SyncCoordinator.monotonicNs())
            cb(unit)
        }
        return true
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

        // Offsets above are 0-based (from withUnsafeBytes); Data's indices
        // start at `startIndex`, which need not be 0 — always offset from it.
        let base = buf.startIndex

        // Emit each NAL between consecutive start codes.
        for k in 0..<(starts.count - 1) {
            let nalStart = starts[k].idx + starts[k].len
            let nalEnd   = starts[k + 1].idx
            if nalEnd > nalStart {
                emit(buf.subdata(in: (base + nalStart)..<(base + nalEnd)))
            }
        }

        // Retain the tail from the last (incomplete) start code onward, as a
        // fresh 0-based buffer.
        let lastIdx = starts[starts.count - 1].idx
        if lastIdx > 0 {
            buf = buf.subdata(in: (base + lastIdx)..<buf.endIndex)
        }
        // Safety cap: a NAL should never exceed a few MB. If the tail grows
        // pathologically (no start code for ages), drop it to avoid OOM.
        if buf.count > 8 * 1024 * 1024 {
            buf.removeAll(keepingCapacity: false)
        }
    }
}
