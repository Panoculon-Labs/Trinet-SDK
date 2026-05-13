package com.panoculon.trinet.sdk.recording

import com.panoculon.trinet.sdk.io.BinaryWriter
import com.panoculon.trinet.sdk.model.TriposeSample
import com.panoculon.trinet.sdk.playback.PoseFileReader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PoseFileRoundTripTest {

    @get:Rule val tmp = TemporaryFolder()

    private fun sample(seed: Float, sofNs: Long) = TriposeSample(
        flags = TriposeSample.FLAG_INITIALIZED,
        filterState = TriposeSample.STATE_TRACKING,
        sofTimestampNs = sofNs,
        positionM = floatArrayOf(seed, seed + 0.1f, seed + 0.2f),
        quatXyzw = floatArrayOf(0.0f, 0.0f, 0.0f, 1.0f),
        velocityMs = floatArrayOf(seed * 0.5f, 0f, 0f),
        gyroBias = floatArrayOf(0.001f, 0.002f, 0.003f),
        accelBias = floatArrayOf(0.01f, 0.02f, 0.03f),
        positionCovDiag = floatArrayOf(0.05f, 0.05f, 0.06f),
        orientCovDiag = floatArrayOf(0.01f, 0.01f, 0.02f),
        numTracked = 17,
        npuLatencyUs = 42,
    )

    @Test fun roundTripFiveRecords() {
        val file = tmp.newFile("pose.bin")
        val samples = (0 until 5).map { sample(seed = it.toFloat(), sofNs = 1_000L + it * 100L) }
        val walls = samples.indices.map { 9_000_000L + it * 50L }

        PoseFileWriter(file).use { w ->
            samples.zip(walls).forEach { (s, t) -> w.append(s, wallClockNs = t) }
        }

        PoseFileReader(file).use { r ->
            assertEquals(samples.size, r.recordCount)
            assertEquals(PoseFileWriter.RECORD_STRIDE_BYTES, r.effectiveStride)
            for (i in samples.indices) {
                val (wall, sample) = r.recordAt(i)
                assertEquals(walls[i], wall)
                assertEquals(samples[i], sample)
            }
        }
    }

    @Test fun readerOverridesBogusHeaderRecordSize() {
        // Forge a file with header record_size = 136 (firmware bug value) but a
        // genuine on-disk stride of 120 — the reader must still parse N records.
        val file = tmp.newFile("pose_legacy.bin")
        val samples = (0 until 3).map { sample(seed = it.toFloat(), sofNs = 5_000L + it * 100L) }

        val header = BinaryWriter(PoseFileWriter.HEADER_SIZE)
        header.bytes(PoseFileWriter.MAGIC)
        header.u32(PoseFileWriter.VERSION.toLong())
        header.u32(136L) // legacy/buggy value
        header.zeros(PoseFileWriter.HEADER_SIZE - 16)
        file.writeBytes(header.toByteArray())

        java.io.FileOutputStream(file, true).use { fos ->
            samples.forEachIndexed { i, s ->
                val w = BinaryWriter(PoseFileWriter.RECORD_STRIDE_BYTES)
                w.u64(2_000_000L + i)
                s.writeTo(w)
                fos.write(w.toByteArray())
            }
        }

        PoseFileReader(file).use { r ->
            assertEquals(136, r.recordSize)
            assertEquals(PoseFileWriter.RECORD_STRIDE_BYTES, r.effectiveStride)
            assertEquals(samples.size, r.recordCount)
            for (i in samples.indices) {
                assertEquals(samples[i], r.sampleAt(i))
            }
        }
    }

    @Test fun indexAtFindsNearestSof() {
        val file = tmp.newFile("pose.bin")
        val sofValues = longArrayOf(1_000L, 2_000L, 3_000L, 4_000L)
        PoseFileWriter(file).use { w ->
            sofValues.forEachIndexed { i, sof ->
                w.append(sample(seed = i.toFloat(), sofNs = sof))
            }
        }
        PoseFileReader(file).use { r ->
            assertTrue(r.indexAt(950L) == 0)
            assertTrue(r.indexAt(1500L) in 0..1)
            assertEquals(2, r.indexAt(2900L))
            assertEquals(3, r.indexAt(10_000L))
        }
    }
}
