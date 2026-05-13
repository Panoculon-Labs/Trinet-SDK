package com.panoculon.trinet.sdk.model

import com.panoculon.trinet.sdk.io.BinaryReader
import com.panoculon.trinet.sdk.io.BinaryWriter

/**
 * v2 `.vts` entry — one per recorded frame. Holds the frame number, the
 * monotonic start-of-frame timestamp used to align IMU samples to video, the
 * encoder sequence number, and the video PTS.
 *
 * Wire layout (24 bytes, little-endian): uint32 frame_number, uint64 sof_timestamp_ns,
 * uint32 venc_seq, uint64 venc_pts_us.
 */
data class VtsEntry(
    val frameNumber: Long,     // unsigned 32-bit
    val sofTimestampNs: Long,
    val vencSeq: Long,         // unsigned 32-bit
    val vencPtsUs: Long,
) {
    companion object {
        const val SIZE_BYTES = 24

        fun read(reader: BinaryReader): VtsEntry = VtsEntry(
            frameNumber = reader.u32(),
            sofTimestampNs = reader.u64(),
            vencSeq = reader.u32(),
            vencPtsUs = reader.u64(),
        )
    }

    fun writeTo(writer: BinaryWriter) {
        writer.u32(frameNumber)
        writer.u64(sofTimestampNs)
        writer.u32(vencSeq)
        writer.u64(vencPtsUs)
    }
}
