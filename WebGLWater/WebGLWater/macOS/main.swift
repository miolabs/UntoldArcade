//
//  main.swift  (macOS)
//  WebGLWater
//
//  Programmatic AppKit entry point. This demo has no Main storyboard, so we set up
//  NSApplication and the delegate explicitly (relying on @main alone does not
//  bootstrap the app delegate without a storyboard).
//

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
