package com.panoculon.trinet.app.data

import android.content.Context
import java.io.File

object AppPaths {
    fun recordingsDir(context: Context): File {
        val ext = context.getExternalFilesDir(null) ?: context.filesDir
        return File(ext, "recordings").apply { if (!exists()) mkdirs() }
    }
}
