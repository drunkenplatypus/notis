import AppKit
import ServiceManagement

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private weak var coordinator: GitHubNotificationCoordinator?
    private var onRefresh: (() -> Void)?

    private let statusValueLabel = NSTextField(labelWithString: "Not configured")
    private let tokenField = NSTextField()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Token", target: nil, action: nil)

    init(coordinator: GitHubNotificationCoordinator, onRefresh: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onRefresh = onRefresh

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 265),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Noti — Preferences"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        buildLayout()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onRefresh?()
    }

    // MARK: - Public

    func refresh() {
        guard let coordinator else { return }
        let detail = coordinator.lastCheckText
        let combined = detail.isEmpty ? coordinator.statusText : "\(coordinator.statusText) — \(detail)"
        statusValueLabel.stringValue = combined
        removeButton.isEnabled = coordinator.isAuthenticated
        launchAtLoginCheckbox.state = LaunchAtLoginManager.isEnabled ? .on : .off
    }

    func focusTokenField() {
        window?.makeFirstResponder(tokenField)
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        // Heading
        let heading = NSTextField(labelWithString: "GitHub Personal Access Token")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        // Status row
        statusValueLabel.textColor = .secondaryLabelColor
        statusValueLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let statusRow = formRow(label: "Status", field: statusValueLabel)

        // Token row
        tokenField.placeholderString = "ghp_…"
        let tokenRow = formRow(label: "Token", field: tokenField)

        // Guidance
        let guidance = NSTextField(wrappingLabelWithString:
            "Classic PAT: enable the \"repo\" scope.\n" +
            "Fine-grained PAT: All repositories → Pull requests (Read) and Issues (Read)."
        )
        guidance.textColor = .secondaryLabelColor
        guidance.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        // Launch-at-login
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        launchAtLoginCheckbox.font = .systemFont(ofSize: 13)

        // Buttons
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        removeButton.bezelStyle = .push
        removeButton.target = self
        removeButton.action = #selector(removeTapped)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.addView(removeButton, in: .leading)
        buttonRow.addView(saveButton, in: .trailing)

        // Outer vertical stack
        let stack = NSStackView(views: [heading, statusRow, tokenRow, guidance, launchAtLoginCheckbox, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            // Stretch these rows to fill the stack width
            tokenRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            guidance.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            launchAtLoginCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    private func formRow(label labelText: String, field: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: labelText + ":")
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        saveButton.isEnabled = false
        removeButton.isEnabled = false

        Task {
            await coordinator?.saveToken(token)
            tokenField.stringValue = ""
            refresh()
            saveButton.isEnabled = true
        }
    }

    @objc private func removeTapped() {
        removeButton.isEnabled = false
        Task {
            await coordinator?.clearToken()
            refresh()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let shouldEnable = launchAtLoginCheckbox.state == .on
        do {
            try LaunchAtLoginManager.setEnabled(shouldEnable)
            refresh()
        } catch {
            launchAtLoginCheckbox.state = LaunchAtLoginManager.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Could not update launch at login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

@MainActor
enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
