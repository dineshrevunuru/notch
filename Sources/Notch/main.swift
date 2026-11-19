import AppKit

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render-previews"), flag + 1 < arguments.count {
    PreviewRenderer.run(into: URL(fileURLWithPath: arguments[flag + 1]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, no menu bar: the notch is the whole interface.
app.setActivationPolicy(.accessory)
app.run()
