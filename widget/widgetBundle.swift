//
//  widgetBundle.swift
//  widget
//
//  Created by apple on 2024/2/18.
//

import WidgetKit
import SwiftUI

extension View {
    /// Removable clear container background.
    /// System Liquid Glass appears only when Appearance → Icon & widget style
    /// is Clear or Tinted (accented mode). Default/fullColor keeps an opaque
    /// system plate for third-party widgets; do not paint Material/white here.
    /// NSWidgetBackgroundColorName / WidgetBackground asset must stay unset/clear.
    @ViewBuilder
    func airBatterySystemWidgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(for: .widget) {
                Color.clear
            }
        } else {
            background(Color.clear)
        }
    }

    @ViewBuilder
    func airBatteryWidgetAccentable() -> some View {
        if #available(macOS 14.0, *) {
            widgetAccentable()
        } else {
            self
        }
    }
}

extension WidgetConfiguration {
    func airBatteryRemovableBackground() -> some WidgetConfiguration {
        if #available(macOS 14.0, *) {
            // Same SPI the native Batteries widget uses (BatteriesAvocadoWidgetExtension imports
            // WidgetConfiguration.preferredBackgroundStyle(.blur)); declared via PrivateWidgetKit/.
            return self.containerBackgroundRemovable(true).preferredBackgroundStyle(.blur)
        } else {
            return self
        }
    }

    /// No longer call contentMarginsDisabled — it edge-fills over system glass.
    func disableContentMarginsIfNeeded() -> some WidgetConfiguration {
        return self
    }
    
    func supportFamily() -> some WidgetConfiguration {
        if #available(macOS 14, *) {
            return self.supportedFamilies([.systemLarge, .systemMedium])
        } else {
            return self.supportedFamilies([.systemLarge, .systemMedium, .systemSmall])
        }
    }
}

@main
struct widgetBundle: WidgetBundle {
    var body: some Widget {
        widgets()
    }
    
    func widgets() -> some Widget {
        if #available(macOS 14, *) {
            return WidgetBundleBuilder.buildBlock(batteryWidget(), batteryWidget2New(), batteryWidget2(), batteryWidget3())
        } else {
            return WidgetBundleBuilder.buildBlock(batteryWidget(), batteryWidget2(), batteryWidget3())
        }
    }
}

extension Image {
    /// In Clear/Tinted (accented) widget style keep device icons legible
    /// instead of flattening them to a solid white blob.
    @ViewBuilder func abAccented() -> some View {
        if #available(macOS 15.0, *) {
            self.widgetAccentedRenderingMode(.accentedDesaturated)
        } else {
            self
        }
    }
}
