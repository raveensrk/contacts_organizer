// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "contacts-organizer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "contacts-organizer",
            path: "Sources/contacts-organizer",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Contacts"),
                // A SwiftPM executable has no bundle, so the usage description that
                // TCC requires is embedded directly into the __TEXT,__info_plist section.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/contacts-organizer/Info.plist",
                ]),
            ]
        )
    ]
)
