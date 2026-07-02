import AppKit

let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
print(hasNotch ? "1" : "0")
