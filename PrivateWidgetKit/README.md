Build-time overlay exposing WidgetKit SPI `WidgetConfiguration.preferredBackgroundStyle(_:)`
and `WidgetBackgroundStyle` (exported by WidgetKit, used by Apple's BatteriesAvocadoWidgetExtension).
Generate on the build Mac: for each arch, concatenate the SDK's
WidgetKit.swiftmodule/<arch>-apple-macos.swiftinterface (arm64 uses arm64e) with
SPI-additions.swiftinterface.txt into PrivateWidgetKit/WidgetKit.swiftmodule/, then run scripts/build.sh.
