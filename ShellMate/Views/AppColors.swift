//
//  Colors.swift
//  ShellMate
//
//  Created by Daniel Delattre on 27/06/24.
//

import SwiftUI
import AppKit

struct AppColors {
    static let gray400 = Color(red: 0.61, green: 0.64, blue: 0.69)
    static let gradientLightBlue = Color(red: 130/255, green: 193/255, blue: 255/255)
    static let gradientPurple = Color(red: 151/255, green: 71/255, blue: 255/255)
}

import SwiftUI

struct ColorManager {
    static let shared = ColorManager()
    
    func color(light: (hex: String, alpha: CGFloat), dark: (hex: String, alpha: CGFloat)) -> Color {
        let lightColor = NSColor(hex: light.hex) ?? NSColor.white
        let darkColor = NSColor(hex: dark.hex) ?? NSColor.black
        
        let dynamicColor = Color(NSColor(name: nil, dynamicProvider: { (appearance) -> NSColor in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                return darkColor.withAlphaComponent(dark.alpha)
            default:
                return lightColor.withAlphaComponent(light.alpha)
            }
        }))
        
        return dynamicColor
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let r, g, b: CGFloat

        var hexColor = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hexColor.hasPrefix("#") {
            hexColor = String(hexColor.dropFirst())
        }

        guard hexColor.count == 6, let hexNumber = UInt64(hexColor, radix: 16) else {
            return nil
        }

        r = CGFloat((hexNumber & 0xFF0000) >> 16) / 255
        g = CGFloat((hexNumber & 0x00FF00) >> 8) / 255
        b = CGFloat(hexNumber & 0x0000FF) / 255

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

extension Color {
    // MARK: - Colors

    struct BG {
        struct Cells {
            static var primary: Color { ColorManager.shared.color(light: ("#1A1B1D", 1.0), dark: ("#1A1B1D", 1.0)) }
            static var secondary: Color { ColorManager.shared.color(light: ("#FFFFFF", 1.0), dark: ("#1A1B1D", 0.05)) }
            static var secondaryFocused: Color { ColorManager.shared.color(light: ("#1A1B1D", 0.05), dark: ("#FFFFFF", 0.05)) }
            static var secondaryClicked: Color { ColorManager.shared.color(light: ("#1A1B1D", 0.05), dark: ("#252628", 1.0)) }
            static var tertiary: Color { ColorManager.shared.color(light: ("#1A1B1D", 0.05), dark: ("#FFFFFF", 0.05)) }
            static var tertiaryFocused: Color { ColorManager.shared.color(light: ("#1A1B1D", 0.15), dark: ("#FFFFFF", 0.15)) }
        }
        struct Onboarding {
            static var purple: Color { ColorManager.shared.color(light: ("#A3BFFF", 1.0), dark: ("#7593ED", 1.0)) }
        }
    }
    
    struct Stroke {
        struct Cells {
            static var secondary: Color { ColorManager.shared.color(light: ("#E5E7EB", 1.0), dark: ("#E5E7EB", 0.2)) }
            static var secondaryFocused: Color { ColorManager.shared.color(light: ("#1A1B1D", 1.0), dark: ("#F3F4F6", 1.0)) }
            static var secondaryClicked: Color { ColorManager.shared.color(light: ("#111827", 1.0), dark: ("#F5F5F5", 1.0)) }
        }
    }

    struct Text {
        static var primary: Color { ColorManager.shared.color(light: ("#1A1B1D", 1.0), dark: ("#F3F4F6", 1.0)) }
        static var secondary: Color { ColorManager.shared.color(light: ("#8E8E93", 1.0), dark: ("#8E8E93", 1.0)) }
        static var white: Color { ColorManager.shared.color(light: ("#F3F4F6", 1.0), dark: ("#F3F4F6", 1.0)) }
        static var gray: Color { ColorManager.shared.color(light: ("#555558", 1.0), dark: ("#D2D2D4", 1.0)) }
        static var green: Color { ColorManager.shared.color(light: ("#2A9F47", 1.0), dark: ("#5DD27A", 1.0)) }
        static var purple: Color { ColorManager.shared.color(light: ("#6618CB", 1.0), dark: ("#6618CB", 1.0)) }
        static var oppositePrimary: Color { ColorManager.shared.color(light: ("#F3F4F6", 1.0), dark: ("#1A1B1D", 1.0)) }
    }
    struct Other {
        static var lightGray: Color { ColorManager.shared.color(light: ("#F3F4F6", 1.0), dark: ("#F3F4F6", 1.0)) }
    }
}
