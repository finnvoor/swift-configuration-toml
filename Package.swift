// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "swift-configuration-toml",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .macCatalyst(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "ConfigurationTOML",
            targets: ["ConfigurationTOML"]
        ),
    ],
    traits: [
        .trait(
            name: "ReloadingSupport",
            description:
                "Adds support for the reloading provider variant, ReloadingTOMLProvider."
        ),
        .default(enabledTraits: [])
    ],
    dependencies: [
        .package(
            url: "https://github.com/czechboy0/swift-configuration",
            branch: "hd-generic-file-providers",
            traits: [.defaults, .trait(name: "ReloadingSupport", condition: .when(traits: ["ReloadingSupport"]))]
        ),
        .package(
            url: "https://github.com/dduan/TOMLDecoder",
            from: "0.3.1"
        )
    ],
    targets: [
        .target(
            name: "ConfigurationTOML",
            dependencies: [
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder")
            ]
        ),
        .testTarget(
            name: "ConfigurationTOMLTests",
            dependencies: [
                "ConfigurationTOML",
                .product(name: "ConfigurationTesting", package: "swift-configuration")
            ],
            resources: [.copy("Resources")]
        ),
    ]
)

for target in package.targets {
    if target.type != .plugin {
        var settings = target.swiftSettings ?? []

        // https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md
        // Require `any` for existential types.
        settings.append(.enableUpcomingFeature("ExistentialAny"))

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
        settings.append(.enableUpcomingFeature("InternalImportsByDefault"))

        settings.append(
            .enableExperimentalFeature(
                "AvailabilityMacro=Configuration 1.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0"
            )
        )

        target.swiftSettings = settings
    }
}
