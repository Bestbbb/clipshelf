import ApplicationServices
import Foundation

/// Recognize the standard Command-V command without depending on menu language.
enum PasteMenuCommand {
    static func matches(role: String?, character: String?, modifiers: Int?, enabled: Bool,
                        supportsPress: Bool) -> Bool {
        role == kAXMenuItemRole && character?.lowercased() == "v" &&
        modifiers == 0 && enabled && supportsPress
    }

    static func find(in application: AXUIElement) -> AXUIElement? {
        guard let bar = attribute(application, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var remaining = 512
        var truncated = false
        var matches: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard matches.count < 2 else { return }
            guard depth <= 8, remaining > 0 else { truncated = true; return }
            remaining -= 1
            let role = attribute(element, kAXRoleAttribute) as? String
            let character = attribute(element, kAXMenuItemCmdCharAttribute) as? String
            if role == kAXMenuItemRole, character?.lowercased() == "v" {
                var actions: CFArray?
                let supportsPress = AXUIElementCopyActionNames(element, &actions) == .success &&
                    (actions as? [String])?.contains(kAXPressAction as String) == true
                if self.matches(role: role, character: character,
                    modifiers: (attribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue,
                    enabled: (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true,
                    supportsPress: supportsPress) { matches.append(element) }
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        walk(bar as! AXUIElement, depth: 0)
        // A truncated traversal or ambiguous shortcut cannot select a command.
        return !truncated && matches.count == 1 ? matches[0] : nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
