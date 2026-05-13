package com.panoculon.trinet.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.panoculon.trinet.app.data.AppPaths
import com.panoculon.trinet.sdk.playback.RecordingFolder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class LibraryViewModel(app: Application) : AndroidViewModel(app) {
    private val _items = MutableStateFlow<List<RecordingFolder>>(emptyList())
    val items: StateFlow<List<RecordingFolder>> = _items.asStateFlow()

    fun refresh() {
        _items.value = RecordingFolder.listIn(AppPaths.recordingsDir(getApplication()))
    }

    fun delete(folder: RecordingFolder) {
        folder.delete()
        refresh()
    }

    /** Returns true if the rename succeeded. */
    fun rename(folder: RecordingFolder, newName: String): Boolean {
        val renamed = folder.renameTo(newName) ?: return false
        refresh()
        return renamed.dir.exists()
    }
}
