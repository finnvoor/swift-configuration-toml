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
            url: "git@github.com:apple/swift-configuration.git",
            .upToNextMinor(from: "0.1.0"),
            traits: [.trait(name: "ReloadingSupport", condition: .when(traits: ["ReloadingSupport"]))]
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

        target.swiftSettings = settings
    }
}
