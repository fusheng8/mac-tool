import AppKit

enum ArchivePasswordPrompt {
    static func requestPassword(
        for archiveURL: URL,
        validator: (String) throws -> Void
    ) throws -> String? {
        precondition(Thread.isMainThread)

        var errorMessage: String?
        while true {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            passwordField.placeholderString = "输入压缩包密码"

            let alert = NSAlert()
            alert.messageText = "压缩包需要密码"
            alert.informativeText = errorMessage ?? "请输入“\(archiveURL.lastPathComponent)”的密码。"
            alert.alertStyle = errorMessage == nil ? .informational : .warning
            alert.accessoryView = passwordField
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")

            passwordField.becomeFirstResponder()
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                return nil
            }

            let password = passwordField.stringValue
            do {
                try validator(password)
                return password
            } catch ArchiveBrowserError.passwordRequired {
                errorMessage = "密码不正确，请重新输入。"
            } catch ArchiveBrowserError.missingTool(let tool) {
                throw ArchiveBrowserError.missingTool(tool)
            } catch ArchiveActionError.missingTool(let tool) {
                throw ArchiveActionError.missingTool(tool)
            } catch ArchiveActionError.passwordProtectedArchive {
                errorMessage = "密码不正确，请重新输入。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
