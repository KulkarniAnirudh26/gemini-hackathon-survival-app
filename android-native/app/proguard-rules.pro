# kotlinx.serialization: keep generated serializers for the map pack model
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class app.survival.mappack.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class app.survival.mappack.**$$serializer { *; }
