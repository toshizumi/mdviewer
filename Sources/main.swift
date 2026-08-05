import AppKit

let launchMode = LaunchMode.parse(Array(CommandLine.arguments.dropFirst()))

if case .usage = launchMode {
    print(LaunchMode.usageText)
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate(mode: launchMode)
application.delegate = appDelegate
// PDF 書き出しモードでは Dock に出さず、メニューバーも奪わない
application.setActivationPolicy(launchMode.isHeadless ? .accessory : .regular)
application.run()
