package com.panoculon.trinet.sdk.playback

import java.io.File

/**
 * Conventional layout of a Trinet recording on disk.
 *
 *   <folder>/video.mp4
 *   <folder>/imu.bin
 *   <folder>/frames.bin
 *   <folder>/meta.json
 */
data class RecordingFolder(val dir: File) {
    val video: File get() = File(dir, "video.mp4")
    val imu: File get() = File(dir, "imu.bin")
    val vts: File get() = File(dir, "frames.bin")
    val meta: File get() = File(dir, "meta.json")

    val isComplete: Boolean get() = video.exists() && imu.exists() && vts.exists()

    /** Recursively delete the recording folder. Returns true on success. */
    fun delete(): Boolean = dir.deleteRecursively()

    /**
     * Rename the on-disk folder (sibling, same parent). Returns the new
     * RecordingFolder on success, or null if the target already exists or the
     * rename failed.
     */
    fun renameTo(newName: String): RecordingFolder? {
        val safe = newName.trim().replace(Regex("[^A-Za-z0-9._-]+"), "_")
        if (safe.isEmpty() || safe == dir.name) return null
        val target = File(dir.parentFile, safe)
        if (target.exists()) return null
        return if (dir.renameTo(target)) RecordingFolder(target) else null
    }

    companion object {
        /** Enumerate child folders that look like recordings. */
        fun listIn(root: File): List<RecordingFolder> {
            if (!root.isDirectory) return emptyList()
            return root.listFiles { f -> f.isDirectory }
                ?.map { RecordingFolder(it) }
                ?.filter { it.video.exists() }
                ?.sortedByDescending { it.video.lastModified() }
                ?: emptyList()
        }
    }
}
