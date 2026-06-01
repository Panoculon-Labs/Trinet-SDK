// VideoDecoder.swift — H.264/H.265 Annex-B → CMSampleBuffer decoder for
// rendering into an AVSampleBufferDisplayLayer. Mirrors what the Android
// SDK does with MediaCodec but iOS-native.
//
// Usage: feed each NAL via `decode(_:)`. Parameter sets (SPS/PPS/[VPS])
// are auto-extracted; once a complete set lands, subsequent VCL NALs get
// wrapped in CMSampleBuffer via the AVCC framing (4-byte length prefix
// + NAL bytes) and emitted via the `onSampleBuffer` callback.

import CoreMedia
import Foundation
import VideoToolbox

public final class VideoDecoder {
    public typealias SampleHandler = @Sendable (CMSampleBuffer) -> Void

    public let codec: VideoCodec
    private let onSampleBuffer: SampleHandler
    private var formatDesc: CMVideoFormatDescription?
    private var frameIndex: Int64 = 0
    private let timeScale: CMTimeScale = 90_000

    // Parameter sets (H.265 also needs VPS).
    private var vps: Data?     // h265 only
    private var sps: Data?
    private var pps: Data?

    public init(codec: VideoCodec, onSampleBuffer: @escaping SampleHandler) {
        self.codec = codec
        self.onSampleBuffer = onSampleBuffer
    }

    public func decode(_ nal: VideoStream.NALUnit) {
        switch codec {
        case .h264: handleH264(nal.payload)
        case .h265: handleH265(nal.payload)
        }
    }

    public func reset() {
        formatDesc = nil
        frameIndex = 0
        vps = nil; sps = nil; pps = nil
    }

    // MARK: - H.264

    private func handleH264(_ nal: Data) {
        guard let first = nal.first else { return }
        let nalType = first & 0x1F
        switch nalType {
        case 7: sps = nal; rebuildH264Format()
        case 8: pps = nal; rebuildH264Format()
        case 1, 5:   // VCL slice (non-IDR, IDR)
            emit(nal: nal, isKey: nalType == 5)
        default:
            break
        }
    }

    private func rebuildH264Format() {
        guard let sps, let pps else { return }
        let arrays: [[UInt8]] = [Array(sps), Array(pps)]
        var fmt: CMVideoFormatDescription?
        var st: OSStatus = noErr
        arrays.withUnsafePointers { ptrs, sizes in
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: 2,
                parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        if st == noErr { self.formatDesc = fmt }
    }

    // MARK: - H.265

    private func handleH265(_ nal: Data) {
        guard let first = nal.first else { return }
        let nalType = (first >> 1) & 0x3F
        switch nalType {
        case 32: vps = nal; rebuildH265Format()
        case 33: sps = nal; rebuildH265Format()
        case 34: pps = nal; rebuildH265Format()
        default:
            // VCL NAL types 0..31; 16..23 are IRAP (keyframes)
            guard nalType <= 31 else { return }
            emit(nal: nal, isKey: nalType >= 16 && nalType <= 23)
        }
    }

    private func rebuildH265Format() {
        guard let vps, let sps, let pps else { return }
        let arrays: [[UInt8]] = [Array(vps), Array(sps), Array(pps)]
        var fmt: CMVideoFormatDescription?
        var st: OSStatus = noErr
        arrays.withUnsafePointers { ptrs, sizes in
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: 3,
                parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil,
                formatDescriptionOut: &fmt)
        }
        if st == noErr { self.formatDesc = fmt }
    }

    // MARK: - Common

    private func emit(nal: Data, isKey: Bool) {
        guard let formatDesc, !nal.isEmpty else { return }

        // AVCC framing: 4-byte big-endian length prefix + NAL bytes.
        let totalLen = nal.count + 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: totalLen)
        var len = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &len) { src in
            bytes.assign(from: src.bindMemory(to: UInt8.self).baseAddress!, count: 4)
        }
        nal.withUnsafeBytes { src in
            if let base = src.bindMemory(to: UInt8.self).baseAddress {
                (bytes + 4).assign(from: base, count: nal.count)
            }
        }

        var block: CMBlockBuffer?
        let st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes,
            blockLength: totalLen,
            blockAllocator: kCFAllocatorDefault,  // takes ownership
            customBlockSource: nil,
            offsetToData: 0, dataLength: totalLen,
            flags: 0, blockBufferOut: &block)
        guard st == noErr, let block else {
            // Allocator didn't take ownership on failure — free manually.
            bytes.deallocate()
            return
        }

        let pts = CMTime(value: frameIndex, timescale: timeScale)
        let dur = CMTime(value: 3000, timescale: timeScale)
        frameIndex += 3000

        var timing = CMSampleTimingInfo(duration: dur,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: pts)
        var sampleSize = totalLen
        var sample: CMSampleBuffer?
        let st2 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard st2 == noErr, let sample else { return }

        // Mark non-keyframes as DependsOnOthers so the display layer can
        // drop them if behind. Defensive: bail if attachments cast fails.
        if !isKey {
            if let attsRaw = CMSampleBufferGetSampleAttachmentsArray(
                    sample, createIfNecessary: true),
               CFArrayGetCount(attsRaw) > 0 {
                let dict = unsafeBitCast(
                    CFArrayGetValueAtIndex(attsRaw, 0),
                    to: CFMutableDictionary.self)
                CFDictionarySetValue(dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }

        onSampleBuffer(sample)
    }
}

// Local helper — keeps Mp4Writer's withUnsafePointers extension internal
// to that file. Duplicated here so VideoDecoder can stand alone without
// depending on Mp4Writer's private extension.
private extension Array where Element == [UInt8] {
    func withUnsafePointers(_ body: (UnsafePointer<UnsafePointer<UInt8>>,
                                     UnsafePointer<Int>) -> Void) {
        let count = self.count
        let pointers = UnsafeMutablePointer<UnsafePointer<UInt8>>.allocate(capacity: count)
        let sizes    = UnsafeMutablePointer<Int>.allocate(capacity: count)
        defer { pointers.deallocate(); sizes.deallocate() }
        for (i, a) in self.enumerated() {
            a.withUnsafeBufferPointer { buf in
                pointers[i] = buf.baseAddress!
                sizes[i] = buf.count
            }
        }
        body(UnsafePointer(pointers), UnsafePointer(sizes))
    }
}
