# LiteRT / LiteRT-LM are called from native code (JNI): keep their classes and native methods.
-keep class com.google.ai.edge.litert.** { *; }
-keepclasseswithmembernames class com.google.ai.edge.litert.** { native <methods>; }
-keep class com.google.ai.edge.litertlm.** { *; }
-keepclasseswithmembernames class com.google.ai.edge.litertlm.** { native <methods>; }
-keep class org.tensorflow.lite.** { *; }
-keepclasseswithmembernames class org.tensorflow.lite.** { native <methods>; }
# JNI_OnLoad in libdynamic_shape_jni.so looks this class up by name (KittenTTS vocoder).
-keep class com.hackathon.yosemite_survival.tts.LiteRtDynamicShape { *; }
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }
# 3D map: the page calls Host.onEvent through the WebView's JavaScript interface.
-keepclassmembers class com.hackathon.yosemite_survival.map3d.** {
    @android.webkit.JavascriptInterface <methods>;
}
