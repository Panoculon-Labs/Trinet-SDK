// AACSupport.swift — turns the device's self-describing ADTS AAC-LC frames
// (recovered from the TRINETAAC SEI) into the CoreMedia objects both the
// recorder (Mp4Writer) and the live player (TrinetAudioPlayer) need:
//
//   * a CMAudioFormatDescription for AAC, built from the ADTS header. CoreMedia
//     wants an ESDS "magic cookie" for kAudioFormatMPEG4AAC; we synthesize it
//     from the 2-byte AudioSpecificConfig derived from the ADTS header.
//   * a compressed CMSampleBuffer per frame (ADTS header stripped → raw AAC),
//     which AVAssetWriterInput (passthrough) and AVSampleBufferAudioRenderer
//     both consume directly.
//
// Keeping this in one place means the muxed-track and live-playback paths share
// exactly one AAC interpretation — no drift between record and preview.

import AudioToolbox
import CoreMedia
import Foundation

/// AAC stream parameters parsed out of an ADTS header.
struct AdtsInfo {
    let sampleRate: Int
    let channels: Int
    let aot: Int          // AudioObjectType (AAC-LC = 2)
    let headerLen: Int    // 7 (no CRC) or 9 (CRC present)
}

enum AACSupport {

    static let sampleRates: [Int] = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350,
    ]

    /// Parse the fixed fields of an ADTS header. Returns nil if the sync word
    /// (0xFFF) is missing or the buffer is too short.
    static func parseAdts(_ d: Data) -> AdtsInfo? {
        guard d.count >= 7 else { return nil }
        let b = [UInt8](d.prefix(7))
        guard b[0] == 0xFF, (b[1] & 0xF0) == 0xF0 else { return nil }
        let aot     = Int((b[2] & 0xC0) >> 6) + 1                // profile(2b) → AOT
        let freqIdx = Int((b[2] & 0x3C) >> 2)
        let chanCfg = Int(((b[2] & 0x01) << 2) | ((b[3] & 0xC0) >> 6))
        let crcAbsent = (b[1] & 0x01) == 1
        let rate = (freqIdx < sampleRates.count) ? sampleRates[freqIdx] : 44100
        let ch   = (chanCfg >= 1 && chanCfg <= 7) ? chanCfg : 2
        return AdtsInfo(sampleRate: rate, channels: ch, aot: aot,
                        headerLen: crcAbsent ? 7 : 9)
    }

    /// 2-byte AudioSpecificConfig (AAC-LC) from parsed ADTS fields.
    static func audioSpecificConfig(_ info: AdtsInfo) -> [UInt8] {
        let freqIdx = sampleRates.firstIndex(of: info.sampleRate) ?? 4   // default 44100
        let b0 = UInt8(((info.aot & 0x1F) << 3) | ((freqIdx & 0x0E) >> 1))
        let b1 = UInt8(((freqIdx & 0x01) << 7) | ((info.channels & 0x0F) << 3))
        return [b0, b1]
    }

    /// Build the MPEG-4 ESDS "magic cookie" CoreMedia expects for AAC, wrapping
    /// the AudioSpecificConfig in the standard ES/DecoderConfig/SL descriptors.
    static func esdsMagicCookie(asc: [UInt8]) -> [UInt8] {
        func len(_ n: Int) -> [UInt8] { [UInt8(n & 0x7F)] }       // small sizes only
        func desc(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag] + len(body.count) + body }

        let dsi = desc(0x05, asc)                                  // DecoderSpecificInfo
        var dcd: [UInt8] = [0x40, 0x15]                            // OTI=AAC, streamType=audio
        dcd += [0x00, 0x00, 0x00]                                  // bufferSizeDB
        dcd += [0x00, 0x00, 0x00, 0x00]                            // maxBitrate
        dcd += [0x00, 0x00, 0x00, 0x00]                            // avgBitrate
        dcd += dsi
        let dcdDesc = desc(0x04, dcd)                              // DecoderConfigDescriptor
        let sl = desc(0x06, [0x02])                                // SLConfigDescriptor (predefined)
        let es: [UInt8] = [0x00, 0x00, 0x00] + dcdDesc + sl       // ES_ID(2)+flags(1)+...
        return desc(0x03, es)                                      // ES_Descriptor
    }

    /// CMAudioFormatDescription for AAC, from a representative ADTS frame.
    static func formatDescription(from adts: Data) -> CMAudioFormatDescription? {
        guard let info = parseAdts(adts) else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(info.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(info.channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        let cookie = esdsMagicCookie(asc: audioSpecificConfig(info))
        var fmt: CMAudioFormatDescription?
        let st = cookie.withUnsafeBytes { raw -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0, layout: nil,
                magicCookieSize: raw.count, magicCookie: raw.baseAddress,
                extensions: nil,
                formatDescriptionOut: &fmt)
        }
        return st == noErr ? fmt : nil
    }

    /// One compressed AAC CMSampleBuffer (ADTS header stripped → raw AAC) with
    /// the given format description and presentation time. `durationSamples` is
    /// the AAC frame length (1024 for AAC-LC), used to derive the sample duration.
    static func sampleBuffer(adts: Data, format: CMAudioFormatDescription,
                             pts: CMTime, durationSamples: Int = 1024) -> CMSampleBuffer? {
        guard let info = parseAdts(adts), adts.count > info.headerLen else { return nil }
        let raw = adts.subdata(in: info.headerLen ..< adts.count)

        var blockBuffer: CMBlockBuffer?
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: raw.count)
        raw.copyBytes(to: UnsafeMutableBufferPointer(start: bytes, count: raw.count))
        let st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: bytes, blockLength: raw.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: raw.count, flags: 0, blockBufferOut: &blockBuffer)
        guard st == noErr, let blockBuffer else { bytes.deallocate(); return nil }

        let sr = CMTimeScale(info.sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(durationSamples), timescale: sr),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = raw.count
        var sample: CMSampleBuffer?
        let st2 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        return st2 == noErr ? sample : nil
    }
}
