import Foundation

// Small, project-local safety baseline. Keep this list conservative and auditable:
// protect OS components, warn on high-value user data, and delegate enterprise
// security agents to their vendor uninstallers.
struct ApplicationUninstallerRuleData {
    static let systemCriticalBundlePatterns: [String] = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.Safari",
        "com.apple.mail",
        "com.apple.systempreferences",
        "com.apple.SystemSettings",
        "com.apple.controlcenter*",
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.SystemUIServer",
        "com.apple.CoreServices*",
        "com.apple.coreservices*",
        "com.apple.security*",
        "com.apple.keychain*",
        "com.apple.trustd*",
        "com.apple.securityd*",
        "com.apple.cloudd*",
        "com.apple.iCloud*",
        "com.apple.SoftwareUpdate*",
        "com.apple.installer*",
        "com.apple.frameworks*",
        "com.apple.backgroundtaskmanagement*",
        "com.apple.loginitems*",
        "com.apple.sharedfilelist*",
        "com.apple.sfl*",
        "com.apple.metadata*",
        "com.apple.inputmethod.*",
        "com.apple.inputsource*",
        "com.apple.TextInput*"
    ]

    static let appleUninstallableBundlePatterns: [String] = [
        "com.apple.dt.*",
        "com.apple.FinalCut*",
        "com.apple.Motion",
        "com.apple.Compressor",
        "com.apple.logic*",
        "com.apple.garageband*",
        "com.apple.iMovie",
        "com.apple.iWork.*",
        "com.apple.Playgrounds"
    ]

    static let dataProtectedPatterns: [String] = [
        "com.1password.*",
        "com.agilebits.*",
        "com.bitwarden.*",
        "com.lastpass.*",
        "com.dashlane.*",
        "com.keepassx.*",
        "org.keepassx.*",
        "org.keepassxc.*",
        "com.authy.*",
        "com.yubico.*",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.*",
        "com.sublimetext.*",
        "com.sublimehq.*",
        "com.jetbrains.*",
        "JetBrains*",
        "com.apple.dt.Xcode",
        "com.docker.*",
        "com.postmanlabs.*",
        "com.tinyspeck.slackmacgap",
        "com.tencent.xinWeChat",
        "com.tencent.qq",
        "com.google.Chrome",
        "org.mozilla.firefox"
    ]

    static let commonLaunchAgentNames: Set<String> = [
        "Agent",
        "Helper",
        "Launcher",
        "Manager",
        "Monitor",
        "Service",
        "Updater",
        "Update",
        "Sync",
        "Client",
        "Server",
        "Worker",
        "Runner",
        "Plugin",
        "Extension",
        "Widget",
        "Utility"
    ]

    static let officialUninstallerRules: [ApplicationUninstallerOfficialRule] = [
        ApplicationUninstallerOfficialRule(
            vendor: "ESET",
            bundlePrefixes: ["com.eset."],
            nameFragments: ["eset management agent", "eset remote administrator agent", "eset endpoint security", "eset endpoint antivirus"]
        ),
        ApplicationUninstallerOfficialRule(
            vendor: "Jamf",
            bundlePrefixes: ["com.jamf.", "com.jamfsoftware."],
            nameFragments: ["jamf connect", "jamf protect", "jamf self service"]
        ),
        ApplicationUninstallerOfficialRule(
            vendor: "CrowdStrike",
            bundlePrefixes: ["com.crowdstrike."],
            nameFragments: ["crowdstrike", "falcon"]
        ),
        ApplicationUninstallerOfficialRule(
            vendor: "SentinelOne",
            bundlePrefixes: ["com.sentinelone.", "com.sentinel-labs."],
            nameFragments: ["sentinelone", "sentinel agent"]
        ),
        ApplicationUninstallerOfficialRule(
            vendor: "GlobalProtect",
            bundlePrefixes: ["com.paloaltonetworks."],
            nameFragments: ["globalprotect"]
        ),
        ApplicationUninstallerOfficialRule(
            vendor: "Cisco",
            bundlePrefixes: ["com.cisco.anyconnect", "com.cisco.secureclient"],
            nameFragments: ["cisco secure client", "cisco anyconnect"]
        )
    ]
}

struct ApplicationUninstallerOfficialRule {
    let vendor: String
    let bundlePrefixes: [String]
    let nameFragments: [String]
}
