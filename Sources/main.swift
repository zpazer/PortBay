import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    // The delegate stays alive because run() never returns.
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
