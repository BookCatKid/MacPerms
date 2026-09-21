import Foundation

struct ServiceInfo: Hashable {
    let name: String          // kTCCService*
    let displayName: String
    let symbol: String        // SF Symbol
    let category: String
    let inSystemDB: Bool
}

enum ServiceCatalog {
    // Services whose records live in the system TCC.db (verified on macOS 27).
    static let systemServices: Set<String> = [
        "kTCCServiceAccessibility",
        "kTCCServiceScreenCapture",
        "kTCCServiceListenEvent",
        "kTCCServicePostEvent",
        "kTCCServiceDeveloperTool",
        "kTCCServiceSystemPolicyAllFiles",
        "kTCCServiceSystemPolicySysAdminFiles",
        "kTCCServiceEndpointSecurityClient",
        "kTCCServiceRemoteDesktop",
    ]

    private static let known: [String: (String, String, String)] = [
        // name : (display, symbol, category)
        "kTCCServiceAccessibility":              ("Accessibility", "accessibility", "System & Input"),
        "kTCCServiceScreenCapture":              ("Screen Recording", "rectangle.dashed.badge.record", "System & Input"),
        "kTCCServiceListenEvent":                ("Input Monitoring", "ear", "System & Input"),
        "kTCCServicePostEvent":                  ("Synthesize Input Events", "keyboard.badge.ellipsis", "System & Input"),
        "kTCCServiceDeveloperTool":              ("Developer Tools", "hammer", "System & Input"),
        "kTCCServiceRemoteDesktop":              ("Remote Desktop", "display.2", "System & Input"),
        "kTCCServiceEndpointSecurityClient":     ("Endpoint Security", "shield.lefthalf.filled", "System & Input"),
        "kTCCServiceAppleEvents":                ("Automation", "applescript", "System & Input"),
        "kTCCServicePasteboard":                 ("Pasteboard", "doc.on.clipboard", "System & Input"),

        "kTCCServiceSystemPolicyAllFiles":       ("Full Disk Access", "internaldrive", "Files & Folders"),
        "kTCCServiceSystemPolicyDesktopFolder":  ("Desktop Folder", "menubar.dock.rectangle", "Files & Folders"),
        "kTCCServiceSystemPolicyDocumentsFolder":("Documents Folder", "doc", "Files & Folders"),
        "kTCCServiceSystemPolicyDownloadsFolder":("Downloads Folder", "arrow.down.circle", "Files & Folders"),
        "kTCCServiceSystemPolicyNetworkVolumes": ("Network Volumes", "network", "Files & Folders"),
        "kTCCServiceSystemPolicyRemovableVolumes":("Removable Volumes", "externaldrive", "Files & Folders"),
        "kTCCServiceSystemPolicyDeveloperFiles": ("Developer Files", "folder.badge.gearshape", "Files & Folders"),
        "kTCCServiceSystemPolicyAppData":        ("App Data", "app.badge", "Files & Folders"),
        "kTCCServiceSystemPolicyAppDataDetailed":("App Data (fine-grained)", "app.badge.checkmark", "Files & Folders"),
        "kTCCServiceSystemPolicyAppBundles":     ("Manage Applications", "square.stack.3d.up", "Files & Folders"),
        "kTCCServiceSystemPolicySysAdminFiles":  ("System Administration Files", "folder.badge.person.crop", "Files & Folders"),
        "kTCCServiceUbiquity":                   ("iCloud Drive", "icloud", "Files & Folders"),
        "kTCCServiceLiverpool":                  ("iCloud Sharing", "icloud.and.arrow.up", "Files & Folders"),
        "kTCCServiceFileProviderDomain":         ("File Provider Domains", "folder.badge.plus", "Files & Folders"),
        "kTCCServiceFileProviderPresence":       ("File Provider Presence", "folder.badge.questionmark", "Files & Folders"),

        "kTCCServiceCamera":                     ("Camera", "camera", "Media"),
        "kTCCServiceMicrophone":                 ("Microphone", "mic", "Media"),
        "kTCCServiceMicrophoneInjection":        ("Microphone Injection", "mic.badge.plus", "Media"),
        "kTCCServiceAudioCapture":               ("Audio Capture", "waveform", "Media"),
        "kTCCServiceExternalCameraMedia":        ("External Camera Media", "camera.on.rectangle", "Media"),
        "kTCCServiceMediaLibrary":               ("Media Library", "music.note.house", "Media"),
        "kTCCServicePhotos":                     ("Photos", "photo.on.rectangle", "Media"),
        "kTCCServicePhotosAdd":                  ("Photos (Add Only)", "photo.badge.plus", "Media"),
        "kTCCServiceScreenCapture_":             ("", "", ""),

        "kTCCServiceAddressBook":                ("Contacts", "person.crop.rectangle", "Personal Data"),
        "kTCCServiceContactsFull":               ("Contacts (Full)", "person.crop.rectangle.fill", "Personal Data"),
        "kTCCServiceContactsLimited":            ("Contacts (Limited)", "person.crop.rectangle.badge.plus", "Personal Data"),
        "kTCCServiceCalendar":                   ("Calendar", "calendar", "Personal Data"),
        "kTCCServiceReminders":                  ("Reminders", "checklist", "Personal Data"),
        "kTCCServiceFocusStatus":                ("Focus Status", "moon.fill", "Personal Data"),
        "kTCCServiceSiri":                       ("Siri", "waveform.circle", "Personal Data"),
        "kTCCServiceSiriAccess":                 ("Siri Access", "waveform.circle.fill", "Personal Data"),
        "kTCCServiceSpeechRecognition":          ("Speech Recognition", "text.bubble", "Personal Data"),
        "kTCCServiceVoiceBanking":               ("Voice Banking", "waveform.path.ecg", "Personal Data"),
        "kTCCServiceWillow":                     ("Home Data", "house", "Personal Data"),
        "kTCCServiceHealthAccessReminder":       ("Health Access Reminder", "heart", "Personal Data"),
        "kTCCServiceMotion":                     ("Motion & Fitness", "figure.walk", "Personal Data"),
        "kTCCServiceFinancialData":              ("Financial Data", "dollarsign.circle", "Personal Data"),
        "kTCCServiceGameCenterFriends":          ("Game Center Friends", "gamecontroller", "Personal Data"),

        "kTCCServiceBluetoothAlways":            ("Bluetooth", "antenna.radiowaves.left.and.right", "Hardware & Network"),
        "kTCCServiceBluetoothPeripheral":        ("Bluetooth Peripheral", "antenna.radiowaves.left.and.right.circle", "Hardware & Network"),
        "kTCCServiceBluetoothWhileInUse":        ("Bluetooth (In Use)", "dot.radiowaves.left.and.right", "Hardware & Network"),
        "kTCCServiceKeyboardNetwork":            ("Keyboard Network", "keyboard", "Hardware & Network"),
        "kTCCServiceNearbyInteraction":          ("Nearby Interaction", "antenna.radiowaves.left.and.right.circle", "Hardware & Network"),
        "kTCCServiceFaceID":                     ("Face ID", "faceid", "Hardware & Network"),
        "kTCCServiceVirtualMachineNetworking":   ("VM Networking", "network.badge.shield.half.filled", "Hardware & Network"),
        "kTCCServiceAccessoryWiFiNetworkSharing":("Accessory Wi-Fi Sharing", "wifi", "Hardware & Network"),
        "kTCCServiceAccessoryAutomaticAudioSwitching":("Accessory Audio Switching", "airpodspro", "Hardware & Network"),
        "kTCCServiceAccessoryLiveActivities":    ("Accessory Live Activities", "rectangle.on.rectangle", "Hardware & Network"),
        "kTCCServiceAccessoryNotifications":     ("Accessory Notifications", "bell.badge", "Hardware & Network"),

        "kTCCServiceUserTracking":               ("App Tracking", "location.viewfinder", "Web & Accounts"),
        "kTCCServiceWebBrowserPublicKeyCredential":("Passkeys", "key", "Web & Accounts"),
        "kTCCServiceWebKitIntelligentTrackingPrevention":("WebKit ITP", "safari", "Web & Accounts"),
        "kTCCServiceFacebook":                   ("Facebook", "f.circle", "Web & Accounts"),
        "kTCCServiceLinkedIn":                   ("LinkedIn", "l.circle", "Web & Accounts"),
        "kTCCServiceTwitter":                    ("Twitter/X", "x.circle", "Web & Accounts"),
        "kTCCServiceSinaWeibo":                  ("Sina Weibo", "s.circle", "Web & Accounts"),
        "kTCCServiceTencentWeibo":               ("Tencent Weibo", "t.circle", "Web & Accounts"),
        "kTCCServiceShareKit":                   ("ShareKit", "square.and.arrow.up", "Web & Accounts"),
        "kTCCServiceExternalAIProviderBlocked":  ("External AI Providers (Blocked)", "brain", "Web & Accounts"),
        "kTCCServiceExternalAIVisibleToSystem":  ("External AI (System Visible)", "brain.head.profile", "Web & Accounts"),

        "kTCCServiceCalls":                      ("Calls", "phone", "Other"),
        "kTCCServiceContactlessAccess":          ("Contactless Access", "wave.3.right", "Other"),
        "kTCCServiceContactlessAccessPayments":  ("Contactless Payments", "creditcard", "Other"),
        "kTCCServiceCrashDetection":             ("Crash Detection", "car", "Other"),
        "kTCCServiceFallDetection":              ("Fall Detection", "figure.fall", "Other"),
        "kTCCServiceExposureNotification":       ("Exposure Notification", "exclamationmark.shield", "Other"),
        "kTCCServiceExposureNotificationRegion": ("Exposure Notification Region", "exclamationmark.shield.fill", "Other"),
        "kTCCServiceMSO":                        ("MSO", "questionmark.circle", "Other"),
        "kTCCServiceSecureElementAccess":        ("Secure Element", "lock.square", "Other"),
        "kTCCServiceAudioAccessoryHeadTrackData":("Head Tracking Data", "airpodsmax", "Other"),
        "kTCCServicePKPassLibraryBackgroundAddPasses":("Wallet Background Add", "wallet.pass", "Other"),
        "kTCCServicePrototype3Rights":           ("Prototype 3", "wrench.and.screwdriver", "Other"),
        "kTCCServicePrototype4Rights":           ("Prototype 4", "wrench.and.screwdriver", "Other"),
        "kTCCServiceAll":                        ("All Services", "asterisk.circle", "Other"),
    ]

    /// System Settings privacy anchors (x-apple.systempreferences:
    /// com.apple.settings.PrivacySecurity.extension?Privacy_<anchor>).
    /// Only mappings verified on modern macOS — anything else falls back to
    /// the Privacy & Security root page.
    private static let anchors: [String: String] = [
        "kTCCServiceAccessibility":      "Accessibility",
        "kTCCServiceScreenCapture":      "ScreenCapture",
        "kTCCServiceListenEvent":        "ListenEvent",
        "kTCCServiceAppleEvents":        "Automation",
        "kTCCServiceSystemPolicyAllFiles": "AllFiles",
        "kTCCServiceSystemPolicyDesktopFolder":  "FilesAndFolders",
        "kTCCServiceSystemPolicyDocumentsFolder":"FilesAndFolders",
        "kTCCServiceSystemPolicyDownloadsFolder":"FilesAndFolders",
        "kTCCServiceCamera":             "Camera",
        "kTCCServiceMicrophone":         "Microphone",
        "kTCCServicePhotos":             "Photos",
        "kTCCServiceAddressBook":        "Contacts",
        "kTCCServiceContactsFull":       "Contacts",
        "kTCCServiceContactsLimited":    "Contacts",
        "kTCCServiceCalendar":           "Calendars",
        "kTCCServiceReminders":          "Reminders",
        "kTCCServiceMediaLibrary":       "MediaLibrary",
        "kTCCServiceSpeechRecognition":  "SpeechRecognition",
        "kTCCServiceBluetoothAlways":    "Bluetooth",
        "kTCCServiceBluetoothWhileInUse":"Bluetooth",
        "kTCCServiceUserTracking":       "UserTracking",
        "kTCCServicePasteboard":         "Pasteboard",
    ]

    /// Deep-link anchor for the service's privacy page, if known.
    static func settingsAnchor(for service: String) -> String? {
        anchors[service]
    }

    static func info(for service: String) -> ServiceInfo {
        if let k = known[service], !k.0.isEmpty {
            return ServiceInfo(name: service, displayName: k.0, symbol: k.1,
                               category: k.2, inSystemDB: systemServices.contains(service))
        }
        // SensorKit and unknown services → generate a readable name.
        var s = service.replacingOccurrences(of: "kTCCService", with: "")
        s = s.replacingOccurrences(of: "SensorKit", with: "SensorKit ")
        let spaced = s.reduce("") { $0 + (($1.isUppercase && !$0.isEmpty) ? " \($1)" : String($1)) }
        let cat = service.contains("SensorKit") ? "SensorKit" : "Other"
        return ServiceInfo(name: service, displayName: spaced, symbol: "questionmark.square",
                           category: cat, inSystemDB: systemServices.contains(service))
    }
}
