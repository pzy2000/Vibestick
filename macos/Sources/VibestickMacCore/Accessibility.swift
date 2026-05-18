import ApplicationServices
import Foundation

public enum AccessibilityStatus {
    public static func isTrusted(prompt: Bool = false) -> Bool {
        let key = "AXTrustedCheckOptionPrompt"
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
