// The XCTest UI-test bundle fast-ios builds once (per Xcode version) to read
// a screen's accessibility tree. Public API only: XCUIApplication(bundleIdentifier:)
// and XCUIElement.snapshot(). Kept as text so the CLI is a single binary.

enum ShotRunnerTemplates {
    static let testSource = #"""
import XCTest

final class AXSnapshotTests: XCTestCase {
    /// One read, configured by environment variables, then the test ends.
    func testSnapshot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bundleID = env["FASTIOS_BUNDLE_ID"], let out = env["FASTIOS_OUT"] else {
            XCTFail("FASTIOS_BUNDLE_ID and FASTIOS_OUT must be set"); return
        }
        let result = try Self.capture(bundleID: bundleID, waitText: env["FASTIOS_WAIT_TEXT"] ?? "",
                                      timeout: Double(env["FASTIOS_TIMEOUT"] ?? "") ?? 20,
                                      acceptOpen: env["FASTIOS_ACCEPT_OPEN"] == "1")
        try Self.write(result, to: out)
    }

    /// Stays running and serves reads: fast-ios drops `req-*.json` files in
    /// FASTIOS_SESSION_DIR; each names the app and the output path. Ends after
    /// FASTIOS_IDLE seconds without a request, or when a `stop` file appears.
    /// `heartbeat` is rewritten every loop so fast-ios can tell it is alive.
    func testSession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FASTIOS_SESSION_DIR"] else { XCTFail("FASTIOS_SESSION_DIR must be set"); return }
        let idle = Double(env["FASTIOS_IDLE"] ?? "") ?? 300
        let fm = FileManager.default
        let heartbeat = URL(fileURLWithPath: dir).appendingPathComponent("heartbeat")
        var lastRequest = Date()
        while Date().timeIntervalSince(lastRequest) < idle {
            try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: heartbeat)
            if fm.fileExists(atPath: dir + "/stop") { break }
            let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasPrefix("req-") && $0.hasSuffix(".json") }.sorted()
            for name in names {
                let path = dir + "/" + name
                defer { try? fm.removeItem(atPath: path) }
                guard let data = fm.contents(atPath: path),
                      let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let out = req["out"] as? String else { continue }
                var result: [String: Any]
                do {
                    result = try Self.capture(bundleID: req["bundleId"] as? String ?? "",
                                              waitText: req["waitText"] as? String ?? "",
                                              timeout: req["timeout"] as? Double ?? 20,
                                              acceptOpen: req["acceptOpen"] as? Bool ?? false)
                } catch {
                    result = ["error": "\(error)"]
                }
                try? Self.write(result, to: out)
                lastRequest = Date()
            }
            if names.isEmpty { usleep(50_000) }
        }
    }

    static func write(_ result: [String: Any], to out: String) throws {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        // Write then rename, so fast-ios never reads half a file.
        let temp = out + ".partial"
        try data.write(to: URL(fileURLWithPath: temp))
        _ = rename(temp, out)
    }

    static func capture(bundleID: String, waitText: String, timeout: Double, acceptOpen: Bool) throws -> [String: Any] {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let started = Date()
        var result: [String: Any] = [:]
        if acceptOpen {
            // `simctl openurl` with a custom scheme asks "Open in “App”?" on
            // iOS 27; the link only reaches the app once Open is tapped.
            let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
            let shown = open.waitForExistence(timeout: 3)
            if shown { open.tap() }
            result["openPromptAccepted"] = shown
        }
        if app.state != .runningForeground { app.activate() }
        if !waitText.isEmpty {
            let match = NSPredicate(format: "label CONTAINS %@ OR identifier == %@", waitText, waitText)
            let found = app.descendants(matching: .any).matching(match).firstMatch.waitForExistence(timeout: timeout)
            result["waitTextFound"] = found
        }
        result["waitSeconds"] = Date().timeIntervalSince(started)
        let snapshot = try app.snapshot()
        result["root"] = Self.encode(snapshot)
        result["appState"] = app.state.rawValue
        return result
    }

    static func encode(_ s: XCUIElementSnapshot) -> [String: Any] {
        var d: [String: Any] = [
            "type": typeName(s.elementType),
            "frame": [s.frame.origin.x, s.frame.origin.y, s.frame.size.width, s.frame.size.height].map { Double($0) },
        ]
        if !s.label.isEmpty { d["label"] = s.label }
        if !s.identifier.isEmpty { d["id"] = s.identifier }
        if !s.title.isEmpty { d["title"] = s.title }
        if let v = s.value { let t = "\(v)"; if !t.isEmpty { d["value"] = t } }
        if let p = s.placeholderValue, !p.isEmpty { d["placeholder"] = p }
        if !s.isEnabled { d["enabled"] = false }
        if s.isSelected { d["selected"] = true }
        if s.hasFocus { d["focused"] = true }
        if !s.children.isEmpty { d["children"] = s.children.map(encode) }
        return d
    }

    static func typeName(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .any: "Any"
        case .other: "Other"
        case .application: "Application"
        case .group: "Group"
        case .window: "Window"
        case .sheet: "Sheet"
        case .drawer: "Drawer"
        case .alert: "Alert"
        case .dialog: "Dialog"
        case .button: "Button"
        case .radioButton: "RadioButton"
        case .radioGroup: "RadioGroup"
        case .checkBox: "CheckBox"
        case .disclosureTriangle: "DisclosureTriangle"
        case .popUpButton: "PopUpButton"
        case .comboBox: "ComboBox"
        case .menuButton: "MenuButton"
        case .toolbarButton: "ToolbarButton"
        case .popover: "Popover"
        case .keyboard: "Keyboard"
        case .key: "Key"
        case .navigationBar: "NavigationBar"
        case .tabBar: "TabBar"
        case .tabGroup: "TabGroup"
        case .toolbar: "Toolbar"
        case .statusBar: "StatusBar"
        case .table: "Table"
        case .tableRow: "TableRow"
        case .tableColumn: "TableColumn"
        case .outline: "Outline"
        case .outlineRow: "OutlineRow"
        case .browser: "Browser"
        case .collectionView: "CollectionView"
        case .slider: "Slider"
        case .pageIndicator: "PageIndicator"
        case .progressIndicator: "ProgressIndicator"
        case .activityIndicator: "ActivityIndicator"
        case .segmentedControl: "SegmentedControl"
        case .picker: "Picker"
        case .pickerWheel: "PickerWheel"
        case .switch: "Switch"
        case .toggle: "Toggle"
        case .link: "Link"
        case .image: "Image"
        case .icon: "Icon"
        case .searchField: "SearchField"
        case .scrollView: "ScrollView"
        case .scrollBar: "ScrollBar"
        case .staticText: "StaticText"
        case .textField: "TextField"
        case .secureTextField: "SecureTextField"
        case .datePicker: "DatePicker"
        case .textView: "TextView"
        case .menu: "Menu"
        case .menuItem: "MenuItem"
        case .menuBar: "MenuBar"
        case .menuBarItem: "MenuBarItem"
        case .map: "Map"
        case .webView: "WebView"
        case .incrementArrow: "IncrementArrow"
        case .decrementArrow: "DecrementArrow"
        case .timeline: "Timeline"
        case .ratingIndicator: "RatingIndicator"
        case .valueIndicator: "ValueIndicator"
        case .splitGroup: "SplitGroup"
        case .splitter: "Splitter"
        case .relevanceIndicator: "RelevanceIndicator"
        case .colorWell: "ColorWell"
        case .helpTag: "HelpTag"
        case .matte: "Matte"
        case .dockItem: "DockItem"
        case .ruler: "Ruler"
        case .rulerMarker: "RulerMarker"
        case .grid: "Grid"
        case .levelIndicator: "LevelIndicator"
        case .cell: "Cell"
        case .layoutArea: "LayoutArea"
        case .layoutItem: "LayoutItem"
        case .handle: "Handle"
        case .stepper: "Stepper"
        case .tab: "Tab"
        case .touchBar: "TouchBar"
        case .statusItem: "StatusItem"
        @unknown default: "Type\(t.rawValue)"
        }
    }
}
"""#

    static let project = #"""
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {
		A10000000000000000000001 /* AXSnapshotTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000000000000000000002; };
		A10000000000000000000002 /* AXSnapshotTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AXSnapshotTests.swift; sourceTree = "<group>"; };
		A10000000000000000000003 /* FastIOSAXRunner.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = FastIOSAXRunner.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
		A10000000000000000000010 = {isa = PBXGroup; children = (A10000000000000000000011, A10000000000000000000012); sourceTree = "<group>"; };
		A10000000000000000000011 /* Tests */ = {isa = PBXGroup; children = (A10000000000000000000002); path = Tests; sourceTree = "<group>"; };
		A10000000000000000000012 /* Products */ = {isa = PBXGroup; children = (A10000000000000000000003); name = Products; sourceTree = "<group>"; };
		A10000000000000000000020 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
		A10000000000000000000030 /* FastIOSAXRunner */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A10000000000000000000050;
			buildPhases = (A10000000000000000000020);
			buildRules = ();
			dependencies = ();
			name = FastIOSAXRunner;
			productName = FastIOSAXRunner;
			productReference = A10000000000000000000003;
			productType = "com.apple.product-type.bundle.ui-testing";
		};
		A10000000000000000000040 /* Project object */ = {
			isa = PBXProject;
			attributes = {LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; };
			buildConfigurationList = A10000000000000000000060;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (en, Base);
			mainGroup = A10000000000000000000010;
			productRefGroup = A10000000000000000000012;
			projectDirPath = "";
			projectRoot = "";
			targets = (A10000000000000000000030);
		};
		A10000000000000000000051 /* Debug target */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				GENERATE_INFOPLIST_FILE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				PRODUCT_BUNDLE_IDENTIFIER = ai.fastios.axrunner;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphonesimulator";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Debug;
		};
		A10000000000000000000050 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000051); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
		A10000000000000000000061 /* Debug project */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ONLY_ACTIVE_ARCH = NO;
				SDKROOT = iphoneos;
				ENABLE_TESTABILITY = YES;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		A10000000000000000000060 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000061); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
	};
	rootObject = A10000000000000000000040;
}
"""#

    static let scheme = #"""
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "A10000000000000000000030" BuildableName = "FastIOSAXRunner.xctest" BlueprintName = "FastIOSAXRunner" ReferencedContainer = "container:FastIOSAXRunner.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "" selectedLauncherIdentifier = "Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "A10000000000000000000030" BuildableName = "FastIOSAXRunner.xctest" BlueprintName = "FastIOSAXRunner" ReferencedContainer = "container:FastIOSAXRunner.xcodeproj"/>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "" selectedLauncherIdentifier = "Xcode.IDEFoundation.Launcher.PosixSpawn" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
   </LaunchAction>
</Scheme>
"""#
}
