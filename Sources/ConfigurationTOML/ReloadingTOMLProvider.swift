#if ReloadingSupport

public import Configuration
public import SystemPackage
public import ServiceLifecycle
public import Logging
public import Metrics
import TOMLDecoder

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A configuration provider that loads values from a TOML file and automatically reloads them when the file changes.
///
/// This provider reads a TOML file from the file system and makes its values
/// available as configuration. Unlike ``TOMLProvider``, this provider continuously
/// monitors the file for changes and automatically reloads the configuration when
/// the file is modified.
///
/// The provider must be run as part of a [`ServiceGroup`](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/documentation/servicelifecycle/servicegroup)
/// for the periodic reloading to work.
///
/// ## Package traits
///
/// This provider is guarded by the `TOMLSupport` and `ReloadingSupport` package traits.
///
/// ## File monitoring
///
/// The provider monitors the TOML file by checking its real path and modification timestamp at regular intervals
/// (default: 15 seconds). When a change is detected, the entire file is reloaded and parsed, and changed keys emit
/// a change event to active watchers.
///
/// ## Watching for changes
///
/// ```swift
/// let config = ConfigReader(provider: provider)
///
/// // Watch for changes to specific values
/// try await config.watchString(forKey: "database.host") { updates in
///     for await host in updates {
///         print("Database host updated: \(host)")
///     }
/// }
/// ```
///
/// ## Similarities to TOMLProvider
///
/// Check out ``TOMLProvider`` to learn more about using TOML for configuration. ``ReloadingTOMLProvider`` is
/// a reloading variant of ``TOMLProvider`` that otherwise follows the same behavior for handling secrets,
/// key and context mapping, and so on.
public final class ReloadingTOMLProvider: Sendable {

    /// The core implementation that handles all reloading logic.
    private let core: ReloadingFileProviderCore<TOMLProviderSnapshot>

    /// Creates a new reloading TOML provider by loading the specified file.
    ///
    /// This initializer loads and parses the TOML file during initialization and
    /// sets up the monitoring infrastructure. The file must contain a valid TOML
    /// document.
    ///
    /// ```swift
    /// // Load configuration from a TOML file with custom settings
    /// let provider = try await ReloadingTOMLProvider(
    ///     filePath: "/etc/app-config.toml",
    ///     pollInterval: .seconds(5),
    ///     secretsSpecifier: .keyBased { key in
    ///         key.contains("password") || key.contains("secret")
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - filePath: The file system path to the TOML configuration file.
    ///   - pollInterval: The interval between file modification checks. Defaults to 15 seconds.
    ///   - bytesDecoder: The decoder used to convert string values to byte arrays.
    ///   - secretsSpecifier: Specifies which configuration values should be treated as secrets.
    ///   - logger: The logger instance to use, or nil to create a default one.
    ///   - metrics: The metrics factory to use, or nil to use a no-op implementation.
    /// - Throws: If the file cannot be read or parsed, or if the TOML structure is invalid.
    public convenience init(
        filePath: FilePath,
        pollInterval: Duration = .seconds(15),
        bytesDecoder: some ConfigBytesFromStringDecoder = .base64,
        secretsSpecifier: SecretsSpecifier<String, Void> = .none,
        logger: Logger? = nil,
        metrics: (any MetricsFactory)? = nil
    ) async throws {
        try await self.init(
            filePath: filePath,
            fileSystem: LocalCommonProviderFileSystem(),
            pollInterval: pollInterval,
            bytesDecoder: bytesDecoder,
            secretsSpecifier: secretsSpecifier,
            logger: logger,
            metrics: metrics
        )
    }

    /// Creates a new reloading TOML provider using a file path from configuration.
    ///
    /// This convenience initializer reads the TOML file path from another
    /// configuration source, allowing the TOML provider to be configured
    /// through configuration itself.
    ///
    /// ```swift
    /// // Configure TOML provider through environment variables
    /// let envProvider = EnvironmentVariablesProvider()
    /// let config = ConfigReader(provider: envProvider)
    ///
    /// // TOML_FILE_PATH environment variable specifies the file
    /// let tomlProvider = try await ReloadingTOMLProvider(
    ///     config: config.scoped(to: "toml"),
    ///     pollInterval: .seconds(30)
    /// )
    /// ```
    ///
    /// ## Required configuration keys
    ///
    /// - `filePath` (string): The file path to the TOML configuration file.
    ///
    /// - Parameters:
    ///   - config: The configuration reader containing the file path.
    ///   - pollInterval: The interval between file modification checks. Defaults to 15 seconds.
    ///   - bytesDecoder: The decoder used to convert string values to byte arrays.
    ///   - secretsSpecifier: Specifies which configuration values should be treated as secrets.
    ///   - logger: The logger instance to use, or nil to create a default one.
    ///   - metrics: The metrics factory to use, or nil to use a no-op implementation.
    /// - Throws: If the file path is missing, or if the file cannot be read or parsed.
    public convenience init(
        config: ConfigReader,
        pollInterval: Duration = .seconds(15),
        bytesDecoder: some ConfigBytesFromStringDecoder = .base64,
        secretsSpecifier: SecretsSpecifier<String, Void> = .none,
        logger: Logger? = nil,
        metrics: (any MetricsFactory)? = nil
    ) async throws {
        try await self.init(
            filePath: config.requiredString(forKey: "filePath", as: FilePath.self),
            pollInterval: pollInterval,
            bytesDecoder: bytesDecoder,
            secretsSpecifier: secretsSpecifier,
            logger: logger,
            metrics: metrics
        )
    }

    /// Creates a new reloading TOML provider.
    /// - Parameters:
    ///   - filePath: The path of the TOML file.
    ///   - fileSystem: The underlying file system.
    ///   - pollInterval: The interval between file modification checks.
    ///   - bytesDecoder: A decoder of bytes from a string.
    ///   - secretsSpecifier: A secrets specifier in case some of the values should be treated as secret.
    ///   - logger: The logger instance to use, or nil to create a default one.
    ///   - metrics: The metrics factory to use, or nil to use a no-op implementation.
    /// - Throws: If the file cannot be read or parsed, or if the TOML structure is invalid.
    internal init(
        filePath: FilePath,
        fileSystem: some CommonProviderFileSystem,
        pollInterval: Duration = .seconds(15),
        bytesDecoder: some ConfigBytesFromStringDecoder = .base64,
        secretsSpecifier: SecretsSpecifier<String, Void> = .none,
        logger: Logger? = nil,
        metrics: (any MetricsFactory)? = nil
    ) async throws {
        self.core = try await ReloadingFileProviderCore(
            filePath: filePath,
            pollInterval: pollInterval,
            providerName: "ReloadingTOMLProvider",
            fileSystem: fileSystem,
            logger: logger,
            metrics: metrics,
            createSnapshot: { data in
                // Parse TOML and create snapshot using existing logic
                guard let contentString = String(data: data, encoding: .utf8) else {
                    throw TOMLProviderSnapshot.TOMLConfigError.parsingFailed(filePath, "File is not valid UTF-8")
                }
                
                let parsedTable: [String: Any]
                do {
                    parsedTable = try TOMLDecoder.tomlTable(from: contentString)
                } catch {
                    throw TOMLProviderSnapshot.TOMLConfigError.parsingFailed(filePath, error.localizedDescription)
                }
                
                let values = try parseValues(
                    parsedTable,
                    keyEncoder: TOMLProviderSnapshot.keyEncoder,
                    secretsSpecifier: secretsSpecifier
                )
                
                return TOMLProviderSnapshot(
                    values: values,
                    bytesDecoder: bytesDecoder
                )
            }
        )
    }
}

extension ReloadingTOMLProvider: Service {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func run() async throws {
        try await core.run()
    }
}

extension ReloadingTOMLProvider: CustomStringConvertible {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public var description: String {
        let snapshot = core.snapshot() as! TOMLProviderSnapshot
        return "ReloadingTOMLProvider[\(snapshot.values.count) values]"
    }
}

extension ReloadingTOMLProvider: CustomDebugStringConvertible {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public var debugDescription: String {
        let snapshot = core.snapshot() as! TOMLProviderSnapshot
        let prettyValues = snapshot.values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "ReloadingTOMLProvider[\(snapshot.values.count) values: \(prettyValues)]"
    }
}

extension ReloadingTOMLProvider: ConfigProvider {
    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public var providerName: String {
        core.providerName
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func value(
        forKey key: AbsoluteConfigKey,
        type: ConfigType
    ) throws -> LookupResult {
        try core.value(forKey: key, type: type)
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func fetchValue(
        forKey key: AbsoluteConfigKey,
        type: ConfigType
    ) async throws -> LookupResult {
        try await core.fetchValue(forKey: key, type: type)
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func watchValue<Return>(
        forKey key: AbsoluteConfigKey,
        type: ConfigType,
        updatesHandler: (
            ConfigUpdatesAsyncSequence<Result<LookupResult, any Error>, Never>
        ) async throws -> Return
    ) async throws -> Return {
        try await core.watchValue(forKey: key, type: type, updatesHandler: updatesHandler)
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func snapshot() -> any ConfigSnapshotProtocol {
        core.snapshot()
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    public func watchSnapshot<Return>(
        updatesHandler: (ConfigUpdatesAsyncSequence<any ConfigSnapshotProtocol, Never>) async throws -> Return
    ) async throws -> Return {
        try await core.watchSnapshot(updatesHandler: updatesHandler)
    }
}

#endif
