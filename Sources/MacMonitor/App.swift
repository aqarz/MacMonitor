import AppKit
import ServiceManagement

@main
enum MacMonitorMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)      // no Dock icon, no app menu
        withExtendedLifetime(delegate) {         // NSApplication.delegate is weak
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Keys {
        static let visible = "panelVisible"
        static let locked = "panelLocked"
    }

    private var sampler: Sampler!
    #if !APPSTORE
    private var remotes: RemoteManager!
    #endif
    private var panel: DesktopPanel!
    private var statusItem: NSStatusItem!

    private var showItem: NSMenuItem!
    private var lockItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    #if !APPSTORE
    private var serversItem: NSMenuItem!
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Keys.visible: true, Keys.locked: true])

        sampler = Sampler()
        #if APPSTORE
        panel = DesktopPanel(sampler: sampler)
        #else
        // Snapshot debug mode shows a fake 'linux-server' instead of connecting over SSH.
        let snapshotMode = !(ProcessInfo.processInfo.environment["MM_SNAPSHOT"] ?? "").isEmpty
        remotes = RemoteManager(demo: snapshotMode)
        panel = DesktopPanel(sampler: sampler, remotes: remotes)
        #endif
        panel.locked = UserDefaults.standard.bool(forKey: Keys.locked)
        if UserDefaults.standard.bool(forKey: Keys.visible) { panel.orderFront(nil) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = "CPU --  RAM --"
        }
        statusItem.menu = buildMenu()

        sampler.onTick = { [weak self] s in self?.updateStatusTitle(s) }
        updateStatusTitle(sampler.snapshot)

        #if APPSTORE
        SnapshotExporter.scheduleIfRequested(sampler: sampler)   // debug: MM_SNAPSHOT=/tmp/panel.png
        #else
        SnapshotExporter.scheduleIfRequested(sampler: sampler, remotes: remotes)   // debug: MM_SNAPSHOT=/tmp/panel.png
        #endif
    }

    private func updateStatusTitle(_ s: Snapshot) {
        let title = String(format: "CPU %2.0f%%  RAM %2.0f%%", s.cpu * 100, s.memFraction * 100)
        if let button = statusItem?.button, button.title != title { button.title = title }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        showItem = NSMenuItem(title: "Hide Desktop Panel",
                              action: #selector(AppDelegate.toggleVisible), keyEquivalent: "")
        lockItem = NSMenuItem(title: "Unlock Position",
                              action: #selector(AppDelegate.toggleLock), keyEquivalent: "")
        loginItem = NSMenuItem(title: "Launch at Login",
                               action: #selector(AppDelegate.toggleLogin), keyEquivalent: "")
        for item in [showItem!, lockItem!, loginItem!] {
            item.target = self
            menu.addItem(item)
        }
        #if !APPSTORE
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Server…", action: #selector(AppDelegate.addServer), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        serversItem = NSMenuItem(title: "Servers", action: nil, keyEquivalent: "")
        serversItem.submenu = NSMenu(title: "Servers")
        menu.addItem(serversItem)
        #endif
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacMonitor", action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showItem.title = panel.isVisible ? "Hide Desktop Panel" : "Show Desktop Panel"
        lockItem.title = panel.locked ? "Unlock Position" : "Lock Position"
        lockItem.isEnabled = panel.isVisible
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        #if !APPSTORE
        rebuildServersMenu()
        #endif
    }

    #if !APPSTORE
    func applicationWillTerminate(_ notification: Notification) {
        remotes?.stopAll()          // SIGTERM every ssh child so no sessions are left behind
    }

    // MARK: Servers

    private func rebuildServersMenu() {
        guard let sub = serversItem.submenu else { return }
        sub.removeAllItems()
        sub.autoenablesItems = false
        let servers = remotes.servers
        serversItem.isEnabled = !servers.isEmpty
        serversItem.title = servers.isEmpty ? "Servers" : "Servers (\(servers.count))"
        for server in servers {
            let item = NSMenuItem(title: server.config.name, action: nil, keyEquivalent: "")
            let detail = NSMenu()
            detail.autoenablesItems = false
            let info = NSMenuItem(title: server.config.displayAddress + " · " + Self.describe(server.status),
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            detail.addItem(info)
            detail.addItem(.separator())
            let reconnect = NSMenuItem(title: "Reconnect", action: #selector(AppDelegate.reconnectServer(_:)),
                                       keyEquivalent: "")
            reconnect.target = self
            reconnect.representedObject = server.id
            detail.addItem(reconnect)
            let remove = NSMenuItem(title: "Remove", action: #selector(AppDelegate.removeServer(_:)),
                                    keyEquivalent: "")
            remove.target = self
            remove.representedObject = server.id
            detail.addItem(remove)
            item.submenu = detail
            sub.addItem(item)
        }
    }

    private static func describe(_ status: RemoteStatus) -> String {
        switch status {
        case .connecting: return "connecting"
        case .online: return "online"
        case .error: return "error"
        }
    }

    @objc private func removeServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        remotes.remove(id: id)
    }

    @objc private func reconnectServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        remotes.reconnect(id: id)
    }

    @objc private func addServer() {
        func field(_ placeholder: String, _ value: String = "") -> NSTextField {
            let f = NSTextField(string: value)
            f.placeholderString = placeholder
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 220).isActive = true
            return f
        }
        let nameField = field("e.g. web-01 (optional)")
        let hostField = field("hostname or IP")
        let userField = field("user", NSUserName())
        let portField = field("22", "22")
        let keyField = field("~/.ssh/id_ed25519 (optional)")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Host:"), hostField],
            [NSTextField(labelWithString: "User:"), userField],
            [NSTextField(labelWithString: "Port:"), portField],
            [NSTextField(labelWithString: "Identity file:"), keyField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Add Server"
        alert.informativeText = "MacMonitor connects with /usr/bin/ssh using key authentication (no passwords). Set up a key first: ssh-copy-id user@host"
        alert.accessoryView = grid
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        nameField.nextKeyView = hostField
        hostField.nextKeyView = userField
        userField.nextKeyView = portField
        portField.nextKeyView = keyField
        keyField.nextKeyView = nameField
        alert.window.initialFirstResponder = hostField

        NSApp.activate(ignoringOtherApps: true)   // accessory app: bring the alert to the front
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trim: (NSTextField) -> String = { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        let host = trim(hostField), user = trim(userField), key = trim(keyField)
        let portText = trim(portField)
        let port = portText.isEmpty ? 22 : (Int(portText) ?? -1)
        var name = trim(nameField)
        if name.isEmpty { name = host }

        let bad: (String) -> Bool = { $0.hasPrefix("-") || $0.contains(where: { $0.isWhitespace || $0 == "@" }) }
        var problem: String?
        if host.isEmpty { problem = "Enter a host name or IP address." }
        else if bad(host) { problem = "The host can't start with '-' or contain spaces or '@'." }
        else if bad(user) { problem = "The user name can't start with '-' or contain spaces or '@'." }
        else if !(1...65535).contains(port) { problem = "The port must be a number from 1 to 65535." }
        if let problem {
            let err = NSAlert()
            err.messageText = "Couldn't add server"
            err.informativeText = problem
            err.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            err.runModal()
            return
        }
        remotes.add(ServerConfig(name: name, host: host, user: user, port: port,
                                 identityFile: key.isEmpty ? nil : key))
    }
    #endif

    @objc private func toggleVisible() {
        let show = !panel.isVisible
        if show { panel.orderFront(nil) } else { panel.orderOut(nil) }
        UserDefaults.standard.set(show, forKey: Keys.visible)
    }

    @objc private func toggleLock() {
        panel.locked.toggle()
        UserDefaults.standard.set(panel.locked, forKey: Keys.locked)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let bundled = Bundle.main.bundleURL.pathExtension == "app"
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = bundled
                ? "\(error.localizedDescription)\n\nTry moving MacMonitor.app to /Applications, or add it manually in System Settings → General → Login Items."
                : "Launch at Login only works when MacMonitor runs from the bundled MacMonitor.app (use build_app.sh)."
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
