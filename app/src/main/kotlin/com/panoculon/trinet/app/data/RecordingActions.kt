package com.panoculon.trinet.app.data

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import com.panoculon.trinet.sdk.playback.RecordingFolder

/**
 * Single place for Library/Player action plumbing. Keeps the screens free of
 * FileProvider/Intent boilerplate.
 */
object RecordingActions {

    /** Build and launch a chooser sharing the recording's video.mp4. */
    fun share(context: Context, folder: RecordingFolder) {
        if (!folder.video.exists()) return
        val authority = "${context.packageName}.fileprovider"
        val uri = FileProvider.getUriForFile(context, authority, folder.video)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, folder.dir.name)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, "Share ${folder.dir.name}").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(chooser)
    }
}
