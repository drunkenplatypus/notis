import AppKit
import ServiceManagement

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private weak var coordinator: GitHubNotificationCoordinator?
    private var onRefresh: (() -> Void)?

    private let statusValueLabel = NSTextField(labelWithString: "Not configured")
    private let tokenField = NSTextField()
    private let notifyReviewRequestedCheckbox = NSButton(checkboxWithTitle: "Review requested", target: nil, action: nil)
    private let notifyPullRequestReviewsCheckbox = NSButton(checkboxWithTitle: "Pull request reviews", target: nil, action: nil)
    private let notifyPullRequestCommentsCheckbox = NSButton(checkboxWithTitle: "Pull request comments", target: nil, action: nil)
    private let notifyReviewCommentsCheckbox = NSButton(checkboxWithTitle: "Inline review comments", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let hideBotActivityCheckbox = NSButton(checkboxWithTitle: "Hide bot comments and reviews", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Token", target: nil, action: nil)

    init(coordinator: GitHubNotificationCoordinator, onRefresh: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onRefresh = onRefresh

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
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
        notifyReviewRequestedCheckbox.state = coordinator.notifyReviewRequested ? .on : .off
        notifyPullRequestReviewsCheckbox.state = coordinator.notifyPullRequestReviews ? .on : .off
        notifyPullRequestCommentsCheckbox.state = coordinator.notifyPullRequestComments ? .on : .off
        notifyReviewCommentsCheckbox.state = coordinator.notifyReviewComments ? .on : .off
        launchAtLoginCheckbox.state = LaunchAtLoginManager.isEnabled ? .on : .off
        hideBotActivityCheckbox.state = coordinator.hideBotActivity ? .on : .off
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

        let notificationTypesHeading = NSTextField(labelWithString: "Notification Types")
        notificationTypesHeading.font = .systemFont(ofSize: 13, weight: .semibold)

        notifyReviewRequestedCheckbox.target = self
        notifyReviewRequestedCheckbox.action = #selector(toggleNotifyReviewRequested)
        notifyReviewRequestedCheckbox.font = .systemFont(ofSize: 13)

        notifyPullRequestReviewsCheckbox.target = self
        notifyPullRequestReviewsCheckbox.action = #selector(toggleNotifyPullRequestReviews)
        notifyPullRequestReviewsCheckbox.font = .systemFont(ofSize: 13)

        notifyPullRequestCommentsCheckbox.target = self
        notifyPullRequestCommentsCheckbox.action = #selector(toggleNotifyPullRequestComments)
        notifyPullRequestCommentsCheckbox.font = .systemFont(ofSize: 13)

        notifyReviewCommentsCheckbox.target = self
        notifyReviewCommentsCheckbox.action = #selector(toggleNotifyReviewComments)
        notifyReviewCommentsCheckbox.font = .systemFont(ofSize: 13)

        let notificationTypesStack = NSStackView(views: [
            notifyReviewRequestedCheckbox,
            notifyPullRequestReviewsCheckbox,
            notifyPullRequestCommentsCheckbox,
            notifyReviewCommentsCheckbox
        ])
        notificationTypesStack.orientation = .vertical
        notificationTypesStack.alignment = .leading
        notificationTypesStack.spacing = 6

        // Launch-at-login
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        launchAtLoginCheckbox.font = .systemFont(ofSize: 13)

        // Bot activity filter
        hideBotActivityCheckbox.target = self
        hideBotActivityCheckbox.action = #selector(toggleHideBotActivity)
        hideBotActivityCheckbox.font = .systemFont(ofSize: 13)

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
        let stack = NSStackView(views: [
            heading,
            statusRow,
            tokenRow,
            guidance,
            notificationTypesHeading,
            notificationTypesStack,
            launchAtLoginCheckbox,
            hideBotActivityCheckbox,
            buttonRow
        ])
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
            notificationTypesStack.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            launchAtLoginCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            hideBotActivityCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
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

    @objc private func toggleNotifyReviewRequested() {
        let enabled = notifyReviewRequestedCheckbox.state == .on
        coordinator?.setNotifyReviewRequested(enabled)
        onRefresh?()
    }

    @objc private func toggleNotifyPullRequestReviews() {
        let enabled = notifyPullRequestReviewsCheckbox.state == .on
        coordinator?.setNotifyPullRequestReviews(enabled)
        onRefresh?()
    }

    @objc private func toggleNotifyPullRequestComments() {
        let enabled = notifyPullRequestCommentsCheckbox.state == .on
        coordinator?.setNotifyPullRequestComments(enabled)
        onRefresh?()
    }

    @objc private func toggleNotifyReviewComments() {
        let enabled = notifyReviewCommentsCheckbox.state == .on
        coordinator?.setNotifyReviewComments(enabled)
        onRefresh?()
    }

    @objc private func toggleHideBotActivity() {
        let shouldHideBotActivity = hideBotActivityCheckbox.state == .on
        coordinator?.setHideBotActivity(shouldHideBotActivity)
        onRefresh?()
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
