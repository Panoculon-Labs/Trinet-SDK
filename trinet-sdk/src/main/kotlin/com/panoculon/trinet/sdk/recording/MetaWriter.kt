package com.panoculon.trinet.sdk.recording

import org.json.JSONObject
import java.io.File

/**
 * Writes `meta.json` describing a recording. Intentionally permissive — extra
 * fields are forward-compatible.
 */
data class RecordingMeta(
    val id: String,
    val createdAtEpochMs: Long,
    val deviceVendorId: Int,
    val deviceProductId: Int,
    val deviceSerial: String?,
    val width: Int,
    val height: Int,
    val fps: Int,
    val codec: String,
    val sdkVersion: String,
)

object MetaWriter {
    fun write(file: File, meta: RecordingMeta) {
        val json = JSONObject().apply {
            put("id", meta.id)
            put("created_at_epoch_ms", meta.createdAtEpochMs)
            put("device", JSONObject().apply {
                put("vendor_id", meta.deviceVendorId)
                put("product_id", meta.deviceProductId)
                put("serial", meta.deviceSerial ?: JSONObject.NULL)
            })
            put("video", JSONObject().apply {
                put("width", meta.width)
                put("height", meta.height)
                put("fps", meta.fps)
                put("codec", meta.codec)
            })
            put("sdk_version", meta.sdkVersion)
        }
        file.writeText(json.toString(2))
    }
}
