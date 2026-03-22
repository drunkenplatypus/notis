import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = GitHubNotificationCoordinator()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var pollTimer: Timer?
    private var preferencesWindowController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategory()
        configureStatusItem()
        statusItem.menu = menu
        rebuildMenu()
        startPolling()

        Task {
            // Temporarily become a regular app so macOS can display the
            // notification permission prompt (accessory apps can't anchor it).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            NSApp.setActivationPolicy(.accessory)

            await coordinator.prepare()
            rebuildMenu()
            updateStatusIcon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
    }

    private func registerNotificationCategory() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_PR",
            title: "Open",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "PR_EVENT",
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        updateStatusIcon()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Status / last check
        let statusItem = NSMenuItem(title: coordinator.statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let lastCheckItem = NSMenuItem(title: coordinator.lastCheckText, action: nil, keyEquivalent: "")
        lastCheckItem.isEnabled = false
        menu.addItem(lastCheckItem)

        // PR sections
        let reviewRequested = coordinator.reviewRequestedPullRequests
        let assigned = coordinator.assignedPullRequests

        if !reviewRequested.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Review Requested"))
            for pr in reviewRequested {
                menu.addItem(makePRMenuItem(pr))
            }
        }

        if !assigned.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Assigned to Me"))
            for pr in assigned {
                menu.addItem(makePRMenuItem(pr))
            }
        }

        // Actions
        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(configureToken), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let checkItem = NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        preferencesWindowController?.refresh()
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    private func makePRMenuItem(_ pr: GitHubPullRequest) -> NSMenuItem {
        let truncated = pr.title.count > 55 ? String(pr.title.prefix(52)) + "…" : pr.title
        let item = NSMenuItem(
            title: "#\(pr.number)  \(truncated)",
            action: #selector(openPR(_:)),
            keyEquivalent: ""
        )
        item.indentationLevel = 1
        item.toolTip = "\(pr.repositoryFullName) #\(pr.number)\n\(pr.title)"
        item.representedObject = pr.htmlURL
        item.target = self
        return item
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runPoll(sendNotifications: true)
            }
        }
    }

    private func refreshMenu() {
        rebuildMenu()
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        if let iconURL = Bundle.main.url(forResource: "huh", withExtension: "png"),
           let rawIcon = NSImage(contentsOf: iconURL),
           let icon = resizedStatusIcon(from: rawIcon) {
            icon.isTemplate = false
            statusItem.button?.image = icon
            return
        }

        // Fallback for development runs where the PNG might not be bundled yet.
        let symbolName = coordinator.isAuthenticated ? "bell.fill" : "bell.slash.fill"
        statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Noti")
    }

    private func resizedStatusIcon(from image: NSImage) -> NSImage? {
        let targetSize = NSSize(width: 18, height: 18)
        let output = NSImage(size: targetSize)

        output.lockFocus()
        defer { output.unlockFocus() }

        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else {
            return nil
        }

        let scale = min(targetSize.width / srcSize.width, targetSize.height / srcSize.height)
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
        let drawRect = NSRect(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)

        return output
    }

    private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                coordinator: coordinator,
                onRefresh: { [weak self] in
                    self?.refreshMenu()
                    self?.updateStatusIcon()
                }
            )
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        preferencesWindowController?.focusTokenField()
    }

    private func runPoll(sendNotifications: Bool) async {
        await coordinator.poll(sendNotifications: sendNotifications)
        refreshMenu()
    }

    @objc
    private func openPR(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    private func configureToken() {
        openPreferences()
    }

    @objc
    private func checkNow() {
        Task {
            await runPoll(sendNotifications: true)
        }
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

@main
struct NotiApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let open = response.actionIdentifier == "OPEN_PR"
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if open,
           let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
