/// What in a built app makes a rule match.
public enum Trigger: Sendable, Hashable, CustomStringConvertible {
    /// A top-level Info.plist key, such as a privacy usage description.
    case infoPlistKey(String)
    /// A `UIBackgroundModes` value.
    case backgroundMode(String)
    /// A top-level entitlement key, from the code signature or, for simulator
    /// builds, the binary's `__TEXT,__entitlements` section.
    case entitlement(String)
    /// A system framework any Mach-O in the bundle links (`otool -L`).
    case framework(String)
    /// An embedded app extension (`PlugIns/*.appex`) with this
    /// `NSExtensionPointIdentifier`.
    case appExtension(String)

    public var description: String {
        switch self {
        case .infoPlistKey(let k): "Info.plist \(k)"
        case .backgroundMode(let m): "UIBackgroundModes \(m)"
        case .entitlement(let e): "entitlement \(e)"
        case .framework(let f): "links \(f).framework"
        case .appExtension(let p): "embeds a \(p) app extension"
        }
    }
}

/// One row of the auto-profile table: when `trigger` is present in the app,
/// keep `keep` running, for `reason`.
public struct CapabilityRule: Sendable, Hashable {
    public let trigger: Trigger
    public let keep: [String]
    public let reason: String
}

/// The auto-profile mapping table. Every label not kept by a matching row is
/// disabled (if it is in ServiceCatalog.slimmable). When in doubt a row keeps
/// more, not less: a kept service costs memory, a missing one breaks a feature.
public enum CapabilityMap {
    static let photos = ["com.apple.assetsd", "com.apple.assetsd.nebulad"]
    static let contacts = ["com.apple.contactsd", "com.apple.contacts.postersyncd", "com.apple.peopled"]
    static let calendars = ["com.apple.calaccessd", "com.apple.dataaccess.dataaccessd"]
    static let reminders = ["com.apple.remindd", "com.apple.calaccessd", "com.apple.dataaccess.dataaccessd"]
    static let push = ["com.apple.apsd"]
    static let health = ["com.apple.healthd", "com.apple.healthappd", "com.apple.healthcontentd"]
    static let home = ["com.apple.homed", "com.apple.homeeventsd"]
    static let siri = [
        "com.apple.assistant_cdmd", "com.apple.assistant_service", "com.apple.siriactionsd",
        "com.apple.siriinferenced", "com.apple.siriknowledged", "com.apple.siri.context.service",
        "com.apple.corespeechd", "com.apple.linkd",
    ]
    static let speech = ["com.apple.corespeechd"]
    static let music = ["com.apple.medialibraryd", "com.apple.musicd", "com.apple.itunescloudd"]
    static let iCloud = [
        "com.apple.cloudd", "com.apple.ckdiscretionaryd", "com.apple.bird", "com.apple.akd",
        "com.apple.appleaccountd",
    ]
    static let storeKit = [
        "com.apple.storekitd", "com.apple.appstored", "com.apple.itunesstored", "com.apple.amsaccountsd",
        "com.apple.amsengagementd", "com.apple.amsondevicestoraged", "com.apple.passd", "com.apple.financed",
    ]
    static let wallet = ["com.apple.passd", "com.apple.financed"]
    static let search = ["com.apple.searchd", "com.apple.corespotlightservice"]
    static let family = [
        "com.apple.familycircled", "com.apple.FamilyControlsAgent", "com.apple.ScreenTimeAgent",
        "com.apple.UsageTrackingAgent", "com.apple.askpermissiond",
    ]
    static let signInWithApple = ["com.apple.akd", "com.apple.appleaccountd", "com.apple.appleidsetupd"]
    static let widgets = ["com.apple.chronod", "com.apple.PosterBoard"]

    public static let rules: [CapabilityRule] = [
        // Privacy usage descriptions in Info.plist
        .init(trigger: .infoPlistKey("NSPhotoLibraryUsageDescription"), keep: photos,
              reason: "Photo picker and PHPhotoLibrary read the library through assetsd."),
        .init(trigger: .infoPlistKey("NSPhotoLibraryAddUsageDescription"), keep: photos,
              reason: "Saving to the library goes through assetsd."),
        .init(trigger: .infoPlistKey("NSContactsUsageDescription"), keep: contacts,
              reason: "CNContactStore and the contact picker read through contactsd."),
        .init(trigger: .infoPlistKey("NSCalendarsUsageDescription"), keep: calendars,
              reason: "EventKit calendar access goes through calaccessd."),
        .init(trigger: .infoPlistKey("NSCalendarsFullAccessUsageDescription"), keep: calendars,
              reason: "EventKit calendar access goes through calaccessd."),
        .init(trigger: .infoPlistKey("NSCalendarsWriteOnlyAccessUsageDescription"), keep: calendars,
              reason: "EventKit write-only access goes through calaccessd."),
        .init(trigger: .infoPlistKey("NSRemindersUsageDescription"), keep: reminders,
              reason: "EventKit reminders go through remindd."),
        .init(trigger: .infoPlistKey("NSRemindersFullAccessUsageDescription"), keep: reminders,
              reason: "EventKit reminders go through remindd."),
        .init(trigger: .infoPlistKey("NSSpeechRecognitionUsageDescription"), keep: speech,
              reason: "SFSpeechRecognizer runs in corespeechd."),
        .init(trigger: .infoPlistKey("NSSiriUsageDescription"), keep: siri,
              reason: "Siri intents and App Intents donations need the Siri daemons."),
        .init(trigger: .infoPlistKey("NSHealthShareUsageDescription"), keep: health,
              reason: "HealthKit reads go through healthd."),
        .init(trigger: .infoPlistKey("NSHealthUpdateUsageDescription"), keep: health,
              reason: "HealthKit writes go through healthd."),
        .init(trigger: .infoPlistKey("NSHomeKitUsageDescription"), keep: home,
              reason: "HomeKit goes through homed."),
        .init(trigger: .infoPlistKey("NSAppleMusicUsageDescription"), keep: music,
              reason: "MediaPlayer and MusicKit read the media library through medialibraryd."),
        .init(trigger: .infoPlistKey("NSUserTrackingUsageDescription"), keep: ["com.apple.ap.adprivacyd"],
              reason: "App Tracking Transparency prompts go through adprivacyd."),
        .init(trigger: .infoPlistKey("NSUbiquitousContainers"), keep: iCloud,
              reason: "iCloud Drive containers sync through bird and cloudd."),
        .init(trigger: .infoPlistKey("UISupportsDocumentBrowser"), keep: search,
              reason: "Recents in the document browser and Files come from searchd."),
        .init(trigger: .infoPlistKey("LSSupportsOpeningDocumentsInPlace"), keep: search,
              reason: "Recents in the document picker come from searchd."),
        .init(trigger: .infoPlistKey("NSSupportsLiveActivities"), keep: ["com.apple.liveactivitiesd"],
              reason: "Live Activities are hosted by liveactivitiesd."),

        // UIBackgroundModes
        .init(trigger: .backgroundMode("remote-notification"), keep: push,
              reason: "Remote and silent push arrive through apsd."),

        // Entitlements
        .init(trigger: .entitlement("aps-environment"), keep: push,
              reason: "Push registration (device token) goes through apsd."),
        .init(trigger: .entitlement("com.apple.developer.associated-domains"), keep: ["com.apple.swcd"],
              reason: "Universal links and webcredentials are verified by swcd."),
        .init(trigger: .entitlement("com.apple.developer.icloud-services"), keep: iCloud,
              reason: "CloudKit and iCloud Documents sync through cloudd and bird."),
        .init(trigger: .entitlement("com.apple.developer.icloud-container-identifiers"), keep: iCloud,
              reason: "CloudKit containers sync through cloudd."),
        .init(trigger: .entitlement("com.apple.developer.ubiquity-kvstore-identifier"),
              keep: iCloud + ["com.apple.syncdefaultsd"],
              reason: "NSUbiquitousKeyValueStore syncs through syncdefaultsd."),
        .init(trigger: .entitlement("com.apple.developer.healthkit"), keep: health,
              reason: "HealthKit goes through healthd."),
        .init(trigger: .entitlement("com.apple.developer.homekit"), keep: home,
              reason: "HomeKit goes through homed."),
        .init(trigger: .entitlement("com.apple.developer.siri"), keep: siri,
              reason: "SiriKit intents need the Siri daemons."),
        .init(trigger: .entitlement("com.apple.developer.in-app-payments"), keep: wallet,
              reason: "The Apple Pay sheet is hosted by passd."),
        .init(trigger: .entitlement("com.apple.developer.pass-type-identifiers"), keep: wallet,
              reason: "Adding passes to Wallet goes through passd."),
        .init(trigger: .entitlement("com.apple.developer.family-controls"), keep: family,
              reason: "FamilyControls and Screen Time APIs need the Screen Time agents."),
        .init(trigger: .entitlement("com.apple.developer.applesignin"), keep: signInWithApple,
              reason: "Sign in with Apple authenticates through akd."),
        .init(trigger: .entitlement("com.apple.developer.devicecheck.appattest-environment"),
              keep: ["com.apple.devicecheckd"], reason: "App Attest goes through devicecheckd."),
        .init(trigger: .entitlement("com.apple.developer.weatherkit"), keep: ["com.apple.weatherd"],
              reason: "WeatherKit requests go through weatherd."),
        .init(trigger: .entitlement("com.apple.developer.game-center"), keep: ["com.apple.gamesaved"],
              reason: "Game Center saved games go through gamesaved (gamed itself is always on)."),
        .init(trigger: .entitlement("com.apple.developer.associated-appclip-app-identifiers"),
              keep: ["com.apple.ClipServices.clipserviced"], reason: "App Clip invocation goes through clipserviced."),

        // Linked system frameworks
        .init(trigger: .framework("Photos"), keep: photos, reason: "Photos.framework talks to assetsd."),
        .init(trigger: .framework("PhotosUI"), keep: photos, reason: "PHPickerViewController talks to assetsd."),
        .init(trigger: .framework("Contacts"), keep: contacts, reason: "Contacts.framework talks to contactsd."),
        .init(trigger: .framework("ContactsUI"), keep: contacts, reason: "The contact picker talks to contactsd."),
        .init(trigger: .framework("EventKit"), keep: reminders, reason: "EventKit talks to calaccessd and remindd."),
        .init(trigger: .framework("HealthKit"), keep: health, reason: "HealthKit talks to healthd."),
        .init(trigger: .framework("HomeKit"), keep: home, reason: "HomeKit talks to homed."),
        .init(trigger: .framework("Speech"), keep: speech, reason: "Speech.framework talks to corespeechd."),
        .init(trigger: .framework("CoreSpotlight"), keep: search,
              reason: "CSSearchableIndex indexes through corespotlightservice and searchd."),
        .init(trigger: .framework("StoreKit"), keep: storeKit,
              reason: "StoreKit purchases and the payment sheet need storekitd and Apple Media Services."),
        .init(trigger: .framework("PassKit"), keep: wallet, reason: "PassKit talks to passd."),
        .init(trigger: .framework("CloudKit"), keep: iCloud, reason: "CloudKit talks to cloudd."),
        .init(trigger: .framework("MediaPlayer"), keep: music, reason: "MediaPlayer reads the library through medialibraryd."),
        .init(trigger: .framework("MusicKit"), keep: music, reason: "MusicKit talks to musicd."),
        .init(trigger: .framework("WeatherKit"), keep: ["com.apple.weatherd"], reason: "WeatherKit talks to weatherd."),
        // WidgetKit is linked by many libraries that ship no widget, and
        // keeping the widget stack costs the most memory of any category, so
        // only an embedded widget extension keeps it.
        .init(trigger: .appExtension("com.apple.widgetkit-extension"), keep: widgets,
              reason: "Widgets are refreshed by chronod and drawn on the Home Screen by PosterBoard."),
        .init(trigger: .framework("ActivityKit"), keep: ["com.apple.liveactivitiesd"],
              reason: "Live Activities are hosted by liveactivitiesd."),
        .init(trigger: .framework("AppIntents"), keep: ["com.apple.linkd"],
              reason: "App Intents metadata is registered with linkd."),
        .init(trigger: .framework("FamilyControls"), keep: family, reason: "FamilyControls talks to the Screen Time agents."),
        .init(trigger: .framework("DeviceCheck"), keep: ["com.apple.devicecheckd"], reason: "DeviceCheck talks to devicecheckd."),
        .init(trigger: .framework("GameKit"), keep: ["com.apple.gamesaved"], reason: "GameKit saved games use gamesaved."),
        .init(trigger: .framework("AppTrackingTransparency"), keep: ["com.apple.ap.adprivacyd"],
              reason: "ATTrackingManager talks to adprivacyd."),
        .init(trigger: .framework("NaturalLanguage"), keep: ["com.apple.naturallanguaged"],
              reason: "Some NaturalLanguage models are served by naturallanguaged."),
    ]
}
