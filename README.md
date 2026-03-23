# noti

A macOS menu bar app that polls GitHub and delivers native notifications for pull request activity.

## Notifications

- **Review requested** — a review has been requested from you on a PR
- **Pull request review** — someone submitted a review on a PR you're assigned to
- **Pull request comment** — someone commented on a PR you're assigned to
- **Review comment** — someone left an inline review comment on a PR you're assigned to

## Setup

1. Build and launch with `make run` from the repo root.
2. Click the bell icon in the menu bar and choose **Preferences…** (or press ⌘,).
3. Paste a GitHub Personal Access Token and click **Save**.

The app polls every 10 seconds. It seeds the current state on first launch so only new activity after startup triggers notifications.

## Preferences

Use **Preferences…** to configure which events generate notifications:

- **Review requested**
- **Pull request reviews**
- **Pull request comments**
- **Inline review comments**

You can also toggle:

- **Hide bot comments and reviews** — suppresses notifications from bot accounts.

All preferences are applied immediately and persisted across app restarts.

## Personal Access Token scopes

### Classic PAT

| Scope  | Reason                                                                                    |
| ------ | ----------------------------------------------------------------------------------------- |
| `repo` | Read access to pull requests, issues, and comments on all public and private repositories |

### Fine-grained PAT

| Setting           | Value                                           |
| ----------------- | ----------------------------------------------- |
| Repository access | **All repositories** (or select specific repos) |
| Pull requests     | **Read-only**                                   |
| Issues            | **Read-only**                                   |

> Issues permission is required because GitHub's search API returns pull requests under the issues endpoint, and issue comments are fetched via the issues comments API.

## Building

Requires macOS 13+ and Swift 6.2+.

`UNUserNotificationCenter` requires a proper `.app` bundle, so `swift run` alone will crash. Use `make` instead — it builds a release binary and wraps it in `noti.app`.

| Command        | Action                                          |
| -------------- | ----------------------------------------------- |
| `make run`     | Build and launch `noti.app` (development)       |
| `make install` | Copy `noti.app` to `~/Applications/`            |
| `make clean`   | Remove the built bundle and `.build/` directory |
