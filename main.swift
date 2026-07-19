import Cocoa

// Explicit bootstrap. NSApplicationMain() loads the main nib and installs the
// nib's delegate, which would discard the one assigned here — so drive the
// application object directly instead.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Menu-bar utility: no Dock icon, no app menu.
app.setActivationPolicy(.accessory)

app.run()
