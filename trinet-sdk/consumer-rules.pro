# Keep JNI entrypoints — called from native code
-keep class com.panoculon.trinet.sdk.transport.NativeBridge { *; }
-keep class com.panoculon.trinet.sdk.transport.NativeBridge$* { *; }

# Keep data classes used in JNI callbacks
-keep class com.panoculon.trinet.sdk.model.** { *; }
