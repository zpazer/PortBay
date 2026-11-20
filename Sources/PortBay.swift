import AppKit
import Combine
import ServiceManagement
import SwiftUI

// Port Bay: a menu bar list of the TCP ports listening on this Mac, with a stop button per process.

struct ProcInfo {
    let executable: String
    let commandLine: String
    let cwd: String
    let name: String
    let isDev: Bool
}

/// Changes from scan to scan, so it is read every time instead of cached.
struct Usage {
    let cpu: Double      // percent of one core, as ps reports it
    let memoryMB: Int
    let uptime: String

    var summary: String {
        let memory = memoryMB >= 1024 ? String(format: "%.1f GB", Double(memoryMB) / 1024) : "\(memoryMB) MB"
        return String(format: "CPU %.1f%%", cpu) + " · \(memory) · up \(uptime)"
    }
}

struct PortProcess: Identifiable {
    let pid: pid_t
    let ports: [Int]
    let exposed: Bool
    let info: ProcInfo
    let usage: Usage?
    var id: pid_t { pid }

    var folder: String? {
        info.cwd.isEmpty || info.cwd == "/" ? nil : (info.cwd as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Scanning

enum PortScanner {
    static func scan(cache: [String: ProcInfo]) -> (processes: [PortProcess], cache: [String: ProcInfo]) {
        var order: [pid_t] = []
        var names: [pid_t: String] = [:]
        var ports: [pid_t: Set<Int>] = [:]
        var exposed: Set<pid_t> = []
        var pid: pid_t = 0
        // -F prints one field per line: p<pid>, c<command>, f<fd>, n<address:port>.
        for line in run("/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn").split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = pid_t(value) ?? 0
                if ports[pid] == nil { order.append(pid); ports[pid] = [] }
            case "c":
                names[pid] = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                ports[pid]?.insert(port)
                if ["*", "0.0.0.0", "[::]"].contains(String(value[..<colon])) { exposed.insert(pid) }
            default:
                break
            }
        }

        // A pid can be reused by another program, so cache by pid and command name together.
        func key(_ pid: pid_t) -> String { "\(pid):\(names[pid] ?? "")" }
        let fresh = details(for: order.filter { cache[key($0)] == nil })
        let usages = usage(for: order)
        var kept: [String: ProcInfo] = [:]
        var processes: [PortProcess] = []
        for pid in order {
            guard let info = cache[key(pid)] ?? fresh[pid] else { continue }
            kept[key(pid)] = info
            processes.append(PortProcess(pid: pid, ports: ports[pid, default: []].sorted(),
                                         exposed: exposed.contains(pid), info: info, usage: usages[pid]))
        }
        processes.sort { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
        return (processes, kept)
    }

    private static func details(for pids: [pid_t]) -> [pid_t: ProcInfo] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let executables = pidColumn(run("/bin/ps", "-ww", "-o", "pid=,comm=", "-p", list))
        let commandLines = pidColumn(run("/bin/ps", "-ww", "-o", "pid=,command=", "-p", list))
        var cwds: [pid_t: String] = [:]
        var pid: pid_t = 0
        for line in run("/usr/sbin/lsof", "-a", "-p", list, "-d", "cwd", "-Fn").split(separator: "\n") {
            if line.first == "p" { pid = pid_t(line.dropFirst()) ?? 0 }
            if line.first == "n" { cwds[pid] = String(line.dropFirst()) }
        }

        var result: [pid_t: ProcInfo] = [:]
        for pid in pids {
            // Gone between lsof and ps: leave it out and let the next scan decide.
            guard let executable = executables[pid] else { continue }
            let commandLine = commandLines[pid] ?? executable
            result[pid] = ProcInfo(executable: executable, commandLine: commandLine, cwd: cwds[pid] ?? "",
                                   name: label(executable, commandLine), isDev: isDev(executable))
        }
        return result
    }

    private static func usage(for pids: [pid_t]) -> [pid_t: Usage] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        var result: [pid_t: Usage] = [:]
        for (pid, rest) in pidColumn(run("/bin/ps", "-o", "pid=,%cpu=,rss=,etime=", "-p", list)) {
            let fields = rest.split(separator: " ")
            guard fields.count == 3, let cpu = Double(fields[0]), let rss = Int(fields[1]) else { continue }
            result[pid] = Usage(cpu: cpu, memoryMB: rss / 1024, uptime: uptime(String(fields[2])))
        }
        return result
    }

    /// ps elapsed time "[[dd-]hh:]mm:ss" as "3d 4h", "2h 15m", "12m" or "<1m".
    private static func uptime(_ elapsed: String) -> String {
        let dayParts = elapsed.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        let hours = clock.count == 3 ? clock[0] : 0
        let minutes = clock.count >= 2 ? clock[clock.count - 2] : 0
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return minutes > 0 ? "\(minutes)m" : "<1m"
    }

    /// Lines of "  <pid> <rest>" from ps, keyed by pid.
    private static func pidColumn(_ output: String) -> [pid_t: String] {
        var map: [pid_t: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { continue }
            map[pid] = trimmed[space...].trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    private static func run(_ path: String, _ arguments: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // A path or argument component that names the dev tool better than "node" or "php" does.
    private static let tools: [String: String] = [
        "vite": "Vite", "next": "Next.js", "nuxt": "Nuxt", "astro": "Astro", "webpack": "webpack",
        "webpack-dev-server": "webpack", "storybook": "Storybook", "remix": "Remix", "react-scripts": "React",
        "nest": "Nest", "expo": "Expo", "nodemon": "nodemon", "tsx": "tsx", "ts-node": "ts-node",
        "laravel": "Laravel", "artisan": "Laravel", "uvicorn": "uvicorn", "gunicorn": "gunicorn",
        "flask": "Flask", "manage.py": "Django", "http.server": "Python http.server", "rails": "Rails",
        "puma": "Puma", "hugo": "Hugo", "jekyll": "Jekyll", "func": "Azure Functions",
    ]

    private static func label(_ executable: String, _ commandLine: String) -> String {
        if let app = appName(executable) { return app }
        for part in commandLine.split(whereSeparator: { " /@=".contains($0) }) {
            if let tool = tools[String(part)] { return tool }
        }
        return (executable as NSString).lastPathComponent
    }

    /// The outermost .app bundle the executable lives in, e.g. "Visual Studio Code".
    private static func appName(_ executable: String) -> String? {
        // Developer tools and Python ship inside .app bundles but are still run by hand.
        guard !executable.contains("/Developer/"), !executable.contains("Python.app") else { return nil }
        guard let bundle = executable.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else { return nil }
        return String(bundle.dropLast(4))
    }

    /// Something you started yourself, as opposed to an app's or macOS's own port.
    private static func isDev(_ executable: String) -> Bool {
        if ["/System/", "/usr/libexec/", "/usr/sbin/"].contains(where: executable.hasPrefix) { return false }
        return appName(executable) == nil
    }
}

// MARK: - Model

@MainActor
final class PortModel: ObservableObject {
    @Published private(set) var processes: [PortProcess] = []
    @Published private(set) var stopping: Set<pid_t> = []
    @Published private(set) var stuck: Set<pid_t> = []
    @Published private(set) var message: String?
    var panelShown = false
    private var cache: [String: ProcInfo] = [:]

    var devProcesses: [PortProcess] { processes.filter { $0.info.isDev } }
    var otherProcesses: [PortProcess] {
        processes.filter { !$0.info.isDev }
            .sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }

    init() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(nanoseconds: panelShown ? 2_000_000_000 : 5_000_000_000)
            }
        }
    }

    func refresh() async {
        let known = cache
        let result = await Task.detached(priority: .utility) { PortScanner.scan(cache: known) }.value
        cache = result.cache
        processes = result.processes
        stuck = stuck.filter(isListening)
    }

    func isListening(_ pid: pid_t) -> Bool { processes.contains { $0.pid == pid } }

    func stop(_ process: PortProcess, force: Bool = false) {
        let name = process.info.name
        guard kill(process.pid, force ? SIGKILL : SIGTERM) == 0 else {
            let reason = errno == EPERM ? "you don't have permission" : String(cString: strerror(errno))
            show("Couldn't stop \(name) (pid \(process.pid)): \(reason).")
            return
        }
        stuck.remove(process.pid)
        stopping.insert(process.pid)
        Task {
            // Give it 3 seconds to close its ports.
            var checks = 0
            while isListening(process.pid) && checks < 6 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await refresh()
                checks += 1
            }
            stopping.remove(process.pid)
            if isListening(process.pid) {
                stuck.insert(process.pid)
                show("\(name) is still running. Click Force to kill it.")
                return
            }
            // brew services, launchd or a file watcher may start it straight back up.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refresh()
            if let back = processes.first(where: { $0.ports.contains(where: process.ports.contains) }) {
                show("\(name) stopped, but \(back.info.name) (pid \(back.pid)) opened the same port again. "
                    + "Something restarts it, for example brew services.")
            } else {
                show("Stopped \(name).")
            }
        }
    }

    private func show(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if message == text { message = nil }
        }
    }
}

// MARK: - Views

extension Color {
    /// Dark yellow, a little brighter on a dark menu so it stays readable.
    static let portNumber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.85, green: 0.68, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.47, blue: 0.00, alpha: 1)
    })
}

/// Shows its content at full height up to `maxHeight`, and scrolls beyond that.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.background(GeometryReader { proxy in
                Color.clear
                    .onAppear { height = proxy.size.height }
                    .onChange(of: proxy.size.height) { height = $0 }
            })
        }
        .frame(height: min(height, maxHeight))
    }
}

struct PortList: View {
    @ObservedObject var model: PortModel
    @AppStorage("showOthers") private var showOthers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Listening ports")
                .font(.headline)
                .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            VStack(spacing: 0) {
                if model.devProcesses.isEmpty {
                    Text("No dev servers running")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                CappedScroll(maxHeight: 290) {
                    VStack(spacing: 2) {
                        ForEach(model.devProcesses) { PortRow(process: $0, model: model) }
                    }
                    .padding(.horizontal, 6)
                }
            }

            if !model.otherProcesses.isEmpty {
                Divider().padding(.vertical, 6)
                Button { showOthers.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showOthers ? 90 : 0))
                        Text("Apps and system")
                        Text(String(model.otherProcesses.count)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)

                if showOthers {
                    CappedScroll(maxHeight: 240) {
                        VStack(spacing: 2) {
                            ForEach(model.otherProcesses) { PortRow(process: $0, model: model) }
                        }
                        .padding(.horizontal, 6)
                    }
                    .padding(.top, 4)
                }
            }

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            Divider().padding(.top, 8)
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
    }
}

struct PortRow: View {
    let process: PortProcess
    @ObservedObject var model: PortModel
    @State private var hovering = false
    @State private var hoveringStop = false
    @State private var armed = false

    var body: some View {
        HStack(spacing: 10) {
            // Clicking anywhere here opens the actions menu; only the stop button stops it.
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(process.ports, id: \.self) { port in
                        Text(String(port))
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .foregroundStyle(Color.portNumber)
                    }
                }
                .frame(width: 52, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(process.info.name).fontWeight(.medium).lineLimit(1)
                        if process.exposed {
                            Image(systemName: "wifi")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("Listening on all interfaces, so other devices on your network can reach it")
                        }
                    }
                    Text(process.folder ?? "pid \(process.pid)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(process.info.commandLine)
                    if let usage = process.usage {
                        Text(usage.summary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(usage.cpu >= 50 ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { showMenu() }

            stopButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                if let title = action.title { Button(title, action: action.run) } else { Divider() }
            }
        }
    }

    @ViewBuilder private var stopButton: some View {
        if model.stuck.contains(process.pid) {
            Button("Force") { model.stop(process, force: true) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .help("Kill it with SIGKILL")
        } else if model.stopping.contains(process.pid) {
            ProgressView().controlSize(.small).frame(width: 22)
        } else if armed {
            Button("Stop?") { armed = false; model.stop(process) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
        } else {
            Button {
                // An app's own port asks twice: stopping it can take the whole app down.
                if process.info.isDev { model.stop(process) } else { arm() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(hoveringStop ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .onHover { hoveringStop = $0 }
            .help("Stop " + process.info.name + " (pid " + String(process.pid) + ")")
        }
    }

    /// What a click or right-click on the row offers. A nil title is a separator.
    private var actions: [(title: String?, run: () -> Void)] {
        var list: [(title: String?, run: () -> Void)] = process.ports.map { port in
            ("Open " + url(port).absoluteString, { NSWorkspace.shared.open(url(port)) })
        }
        if process.folder != nil {
            list.append(("Show Folder in Finder", {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: process.info.cwd)])
            }))
        }
        list.append(("Copy PID", { copy(String(process.pid)) }))
        list.append(("Copy Command", { copy(process.info.commandLine) }))
        list.append((nil, {}))
        list.append(("Force Kill", { model.stop(process, force: true) }))
        return list
    }

    private func showMenu() {
        let menu = NSMenu()
        for action in actions {
            guard let title = action.title else {
                menu.addItem(.separator())
                continue
            }
            let handler = MenuHandler(action.run)
            let item = NSMenuItem(title: title, action: #selector(MenuHandler.run), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler // target is weak; this keeps the handler alive
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func arm() {
        armed = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            armed = false
        }
    }

    private func url(_ port: Int) -> URL { URL(string: "http://localhost:" + String(port))! }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class MenuHandler: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}

// MARK: - Menu bar

/// The dropdown under the menu bar icon. An NSPopover re-anchors to the status item every time it
/// resizes, and when macOS moves or hides the icon (the notch, a crowded menu bar, a second display)
/// it jumps to the screen's left edge. This panel stays where it opened.
final class DropdownPanel: NSPanel {
    var onClose: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 12)
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    // Clicking anywhere else takes focus away, which closes it like a menu.
    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PortModel()
    private var statusItem: NSStatusItem!
    private var host: NSHostingController<PortList>!
    private var panel: DropdownPanel!
    private var isOpen = false
    private var closedAt = Date.distantPast
    private var top = NSPoint.zero
    private var screen: NSScreen?
    private var clickMonitor: Any?
    private weak var openedFrom: NSStatusBarButton?
    private var sizeObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "PortBay"
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Listening ports")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel(_:))
        }

        host = NSHostingController(rootView: PortList(model: model))
        host.sizingOptions = .preferredContentSize
        panel = DropdownPanel(content: host.view)
        panel.onClose = { [weak self] in self?.closePanel() }
        sizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                if let size = change.newValue { self?.place(size: size) }
            }
        }
        Task { askToOpenAtLogin() }
    }

    // Asked once, on the first launch. After that it's changed in System Settings → General → Login Items.
    private func askToOpenAtLogin() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "askedOpenAtLogin") else { return }
        defaults.set(true, forKey: "askedOpenAtLogin")
        guard SMAppService.mainApp.status != .enabled else { return }

        let alert = NSAlert()
        alert.messageText = "Open Port Bay when you log in?"
        alert.informativeText = "Port Bay lives in the menu bar. It can start by itself each time you log in, "
            + "so your ports are always one click away.\n\nYou can change this later in System Settings → General → Login Items."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // Opening the app again (Spotlight, Finder) shows the panel, so it can be reached even when
    // macOS has hidden the icon in a full menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.isVisible = true // brings the icon back if it was ⌘-dragged out of the menu bar
        if !isOpen { openPanel(clicked: nil) }
        return false
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        // Clicking the icon while the panel is open takes focus first, which has just closed it.
        if isOpen || Date().timeIntervalSince(closedAt) < 0.3 {
            closePanel()
            return
        }
        openPanel(clicked: sender)
    }

    private func openPanel(clicked: NSStatusBarButton?) {
        // Remember where the icon is now; the panel keeps this top edge while it is open.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let button = clicked ?? statusItem.button
        var icon = button.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        } ?? .zero
        // The icon can be a copy on another display, or parked off-screen when macOS hides it
        // (crowded menu bar, notch). Then go by the click, or the top right where menu bar icons live.
        if let screen, !screen.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) {
            let barHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            let x = clicked == nil ? screen.frame.maxX : mouse.x
            icon = NSRect(x: x, y: screen.frame.maxY - barHeight, width: 0, height: barHeight)
        }
        self.screen = screen
        top = NSPoint(x: icon.midX, y: min(icon.minY, screen?.visibleFrame.maxY ?? icon.minY) - 4)
        isOpen = true
        place(size: host.sizeThatFits(in: NSSize(width: 10_000, height: 10_000)))
        panel.makeKeyAndOrderFront(nil)
        button?.highlight(true)
        openedFrom = button
        model.panelShown = true
        // A click in another app closes it, like a menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        Task { await model.refresh() }
    }

    private func closePanel() {
        guard isOpen else { return }
        isOpen = false
        closedAt = Date()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel.orderOut(nil)
        openedFrom?.highlight(false)
        model.panelShown = false
    }

    /// Grows and shrinks downwards from the remembered top edge, kept on the same screen.
    private func place(size: NSSize) {
        guard isOpen, size.width > 0, size.height > 0 else { return }
        var x = top.x - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: top.y - size.height, width: size.width, height: size.height), display: true)
    }
}
