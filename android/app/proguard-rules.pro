# kotlinx.serialization keeps generated serializers
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class com.ooimi.agents.status.data.** {
    *** Companion;
}
-keepclasseswithmembers class com.ooimi.agents.status.data.** {
    kotlinx.serialization.KSerializer serializer(...);
}
