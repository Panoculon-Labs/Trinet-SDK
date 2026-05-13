package com.panoculon.trinet.sdk.session

/**
 * Stream parameters requested when opening a [TrinetSession]. The device must
 * advertise a matching format/resolution/fps combination — defaults target
 * what a Trinet camera ships with out of the box.
 */
data class SessionConfig(
    val width: Int = 1920,
    val height: Int = 1080,
    val fps: Int = 30,
)
