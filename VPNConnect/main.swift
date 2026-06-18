import Cocoa

// Explicitly set the application delegate before NSApplicationMain starts the run loop.
// This is required because we don't have a Main.storyboard or MainMenu.xib to wire it up.
// NOTE: Use NSApplication.shared, NOT NSApp — NSApp is an IUO that isn't set until
// NSApplicationMain() runs, so accessing it before that call crashes with a nil unwrap.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
