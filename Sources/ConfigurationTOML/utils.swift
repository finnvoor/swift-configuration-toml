//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftConfiguration open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftConfiguration project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftConfiguration project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(FoundationEssentials)
package import FoundationEssentials
#else
package import Foundation
#endif
package import Configuration
package import SystemPackage
import Synchronization

/// A file system abstraction used by some of the providers in Configuration.
package protocol CommonProviderFileSystem: Sendable {
    /// Loads the file contents at the specified file path.
    /// - Parameter filePath: The path to the file.
    /// - Returns: The byte contents of the file.
    /// - Throws: When the file cannot be read.
    func fileContents(atPath filePath: FilePath) async throws -> Data

    /// Reads the last modified timestamp of the file, if it exists.
    /// - Parameter filePath: The file path to check.
    /// - Returns: The last modified timestamp, if found. Nil if the file is not found.
    /// - Throws: When any other attribute reading error occurs.
    func lastModifiedTimestamp(atPath filePath: FilePath) async throws -> Date

    /// Lists all regular file names in the specified directory.
    /// - Parameter directoryPath: The path to the directory.
    /// - Returns: An array of file names in the directory.
    /// - Throws: When the directory cannot be read or doesn't exist.
    func listFileNames(atPath directoryPath: FilePath) async throws -> [String]

    /// Resolves symlinks and returns the real file path.
    ///
    /// If the provided path is not a symlink, returns the same unmodified path.
    /// - Parameter filePath: The file path that may contain symlinks.
    /// - Returns: The resolved file path with symlinks resolved.
    /// - Throws: When the path cannot be resolved.
    func resolveSymlinks(atPath filePath: FilePath) async throws -> FilePath
}

/// A file system implementation that uses the local file system.
package struct LocalCommonProviderFileSystem: Sendable {
    /// The error thrown by the file system.
    package enum FileSystemError: Error, CustomStringConvertible {
        /// The directory was not found at the provided path.
        case directoryNotFound(path: FilePath)

        /// Failed to read a file in the directory.
        case fileReadError(filePath: FilePath, underlyingError: any Error)

        /// Failed to read a file in the directory.
        case missingLastModifiedTimestampAttribute(filePath: FilePath)

        /// The path exists but is not a directory.
        case notADirectory(path: FilePath)

        package var description: String {
            switch self {
            case .directoryNotFound(let path):
                return "Directory not found at path: \(path)."
            case .fileReadError(let filePath, let error):
                return "Failed to read file '\(filePath)': \(error)."
            case .missingLastModifiedTimestampAttribute(let filePath):
                return "Missing last modified timestamp attribute for file '\(filePath)."
            case .notADirectory(let path):
                return "Path exists but is not a directory: \(path)."
            }
        }
    }
}

extension LocalCommonProviderFileSystem: CommonProviderFileSystem {
    package func fileContents(atPath filePath: FilePath) async throws -> Data {
        do {
            return try Data(contentsOf: URL(filePath: filePath.string))
        } catch {
            throw FileSystemError.fileReadError(
                filePath: filePath,
                underlyingError: error
            )
        }
    }

    package func lastModifiedTimestamp(atPath filePath: FilePath) async throws -> Date {
        guard
            let timestamp = try FileManager().attributesOfItem(atPath: filePath.string)[.modificationDate]
                as? Date
        else {
            throw FileSystemError.missingLastModifiedTimestampAttribute(filePath: filePath)
        }
        return timestamp
    }

    package func listFileNames(atPath directoryPath: FilePath) async throws -> [String] {
        let fileManager = FileManager.default
        #if canImport(Darwin)
        var isDirectoryWrapper: ObjCBool = false
        #else
        var isDirectoryWrapper: Bool = false
        #endif
        guard fileManager.fileExists(atPath: directoryPath.string, isDirectory: &isDirectoryWrapper) else {
            throw FileSystemError.directoryNotFound(path: directoryPath)
        }
        #if canImport(Darwin)
        let isDirectory = isDirectoryWrapper.boolValue
        #else
        let isDirectory = isDirectoryWrapper
        #endif
        guard isDirectory else {
            throw FileSystemError.notADirectory(path: directoryPath)
        }
        return
            try fileManager
            .contentsOfDirectory(atPath: directoryPath.string)
            .filter { !$0.hasPrefix(".") }
            .compactMap { (fileName) -> String? in
                // Skip non-regular files (directories, symlinks, etc.)
                let attributes =
                    try fileManager
                    .attributesOfItem(atPath: directoryPath.appending(fileName).string)
                guard let type = (attributes[.type] as? FileAttributeType), type == FileAttributeType.typeRegular else {
                    return nil
                }
                return fileName
            }
    }

    package func resolveSymlinks(atPath filePath: FilePath) async throws -> FilePath {
        FilePath(URL(filePath: filePath.string).resolvingSymlinksInPath().path())
    }
}

/// An error thrown by Configuration module types.
///
/// These errors indicate issues with configuration value retrieval or conversion.
package enum ConfigError: Error, CustomStringConvertible, Equatable {

    /// A required configuration value was not found in any provider.
    case missingRequiredConfigValue(AbsoluteConfigKey)

    /// A configuration value could not be converted to the expected type.
    case configValueNotConvertible(name: String, type: ConfigType)

    /// A configuration value could not be cast to the expected type.
    case configValueFailedToCast(name: String, type: String)

    package var description: String {
        switch self {
        case .missingRequiredConfigValue(let key):
            return "Missing required config value for key: \(key)."
        case .configValueNotConvertible(let name, let type):
            return "Config value for key '\(name)' failed to convert to type \(type)."
        case .configValueFailedToCast(let name, let type):
            return "Config value for key '\(name)' failed to cast to type \(type)."
        }
    }
}

/// Creates a lookup result from an asynchronous configuration value retrieval operation.
///
/// This convenience function simplifies provider implementations by handling the
/// common pattern of executing an async closure that returns an optional configuration
/// value and wraps the result in a ``LookupResult``.
///
/// The following example shows using this convenience function:
///
/// ```swift
/// func fetchValue(forKey: AbsoluteConfigKey, type: ConfigType) async throws -> LookupResult {
///     let encodedKey = encodeKey(key)
///     return await withConfigValueLookup(encodedKey: encodedKey) {
///         // Asynchronously fetch the value from a remote source
///         try await fetchRemoteValue(forKey: encodedKey, type: type)
///     }
/// }
/// ```
///
/// - Parameters:
///   - encodedKey: The provider-specific encoding of the configuration key.
///   - work: An async closure that performs the value lookup and returns the result.
/// - Returns: A lookup result containing the encoded key and the value from the closure.
/// - Throws: Rethrows any errors thrown by the provided closure.
package func withConfigValueLookup<Failure: Error>(
    encodedKey: String,
    work: () async throws(Failure) -> ConfigValue?
) async throws(Failure) -> LookupResult {
    let value = try await work()
    return .init(encodedKey: encodedKey, value: value)
}

/// Creates a lookup result from a configuration value retrieval operation.
///
/// This convenience function simplifies provider implementations by handling the
/// common pattern of executing a closure that returns an optional configuration
/// value and wraps the result in a ``LookupResult``.
///
/// The following example shows using this convenience function:
///
/// ```swift
/// func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
///     let encodedKey = encodeKey(key)
///     return withConfigValueLookup(encodedKey: encodedKey) {
///         // Look up the value in your data source
///         return findValue(forKey: encodedKey, type: type)
///     }
/// }
/// ```
///
/// - Parameters:
///   - encodedKey: The provider-specific encoding of the configuration key.
///   - work: A closure that performs the value lookup and returns the result.
/// - Returns: A lookup result containing the encoded key and the value from the closure.
/// - Throws: Rethrows any errors thrown by the provided closure.
package func withConfigValueLookup<Failure: Error>(
    encodedKey: String,
    work: () throws(Failure) -> ConfigValue?
) throws(Failure) -> LookupResult {
    let value = try work()
    return .init(encodedKey: encodedKey, value: value)
}

/// A simple in-memory file system used for testing.
package final class InMemoryFileSystem: Sendable {

    /// Represents the type of data stored in the in-memory file system.
    ///
    /// Used to model both regular files and symbolic links.
    package enum FileData: Sendable {
        /// Represents a symbolic link to another file in the file system.
        /// - Parameter FilePath: The target location that this symlink points to.
        case symlink(FilePath)

        /// Represents a regular file with actual content.
        /// - Parameter Data: The raw binary content of the file.
        case file(Data)
    }

    /// Represents metadata and content information for a file in the in-memory file system.
    ///
    /// This struct combines both the file's content data and relevant metadata like modification time.
    package struct FileInfo: Sendable {
        /// The timestamp when the file was last modified.
        package var lastModifiedTimestamp: Date

        /// The actual content data of the file, either as regular file content or as a symbolic link.
        package var data: FileData

        package init(lastModifiedTimestamp: Date, data: FileData) {
            self.lastModifiedTimestamp = lastModifiedTimestamp
            self.data = data
        }
    }

    /// The files in the file system, keyed by file name.
    private let files: Mutex<[FilePath: FileInfo]>

    /// Creates a new in-memory file system with the given files.
    /// - Parameter files: The files in the file system, keyed by file path.
    package init(files: [FilePath: FileInfo]) {
        self.files = .init(files)
    }

    /// A test error.
    enum TestError: Error {
        /// The requested file was not found.
        case fileNotFound(filePath: FilePath)
    }

    /// Updates or adds a file in the in-memory file system with the specified content and timestamp.
    ///
    /// This method allows you to modify existing files or create new files in the file system.
    /// If a file already exists at the specified path, it will be completely replaced with the new data.
    /// If no file exists at the path, a new file entry will be created.
    ///
    /// - Parameters:
    ///   - filePath: The file path where the file should be stored or updated in the file system.
    ///   - timestamp: The last modified timestamp to associate with the file.
    ///   - contents: The file data to store, which can be either regular file content or a symbolic link.
    package func update(filePath: FilePath, timestamp: Date, contents: FileData) {
        files.withLock { files in
            files[filePath] = .init(lastModifiedTimestamp: timestamp, data: contents)
        }
    }

    /// Removes a file from the in-memory file system.
    ///
    /// This method deletes the file at the specified path from the file system.
    /// If the file does not exist, the operation completes silently without error.
    ///
    /// - Parameter filePath: The file path of the file to remove from the file system.
    package func remove(filePath: FilePath) {
        files.withLock { files in
            _ = files.removeValue(forKey: filePath)
        }
    }
}

extension InMemoryFileSystem: CommonProviderFileSystem {
    package func listFileNames(atPath directoryPath: FilePath) async throws -> [String] {
        let prefixComponents = directoryPath.components
        return files.withLock { files in
            files
                .filter { (filePath, _) in
                    let components = filePath.components
                    guard components.count == prefixComponents.count + 1 else {
                        return false
                    }
                    return Array(prefixComponents) == Array(components.dropLast())
                }
                .compactMap { $0.key.lastComponent?.string }
        }
    }

    package func lastModifiedTimestamp(atPath filePath: FilePath) async throws -> Date {
        try files.withLock { files in
            guard let data = files[filePath] else {
                throw LocalCommonProviderFileSystem.FileSystemError.fileReadError(
                    filePath: filePath,
                    underlyingError: TestError.fileNotFound(filePath: filePath)
                )
            }
            return data.lastModifiedTimestamp
        }
    }

    package func fileContents(atPath filePath: FilePath) async throws -> Data {
        let data = try files.withLock { files in
            guard let data = files[filePath] else {
                throw LocalCommonProviderFileSystem.FileSystemError.fileReadError(
                    filePath: filePath,
                    underlyingError: TestError.fileNotFound(filePath: filePath)
                )
            }
            return data
        }
        switch data.data {
        case .file(let data):
            return data
        case .symlink(let target):
            return try await fileContents(atPath: target)
        }
    }

    package func resolveSymlinks(atPath filePath: FilePath) async throws -> FilePath {
        func locked_resolveSymlinks(at filePath: FilePath, files: inout [FilePath: FileInfo]) throws -> FilePath {
            guard let data = files[filePath] else {
                throw LocalCommonProviderFileSystem.FileSystemError.fileReadError(
                    filePath: filePath,
                    underlyingError: TestError.fileNotFound(filePath: filePath)
                )
            }
            switch data.data {
            case .file:
                return filePath
            case .symlink(let target):
                return try locked_resolveSymlinks(at: target, files: &files)
            }
        }
        return try files.withLock { files in
            try locked_resolveSymlinks(at: filePath, files: &files)
        }
    }
}

#if ReloadingSupport
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
#endif
import ServiceLifecycle
import Logging
import Metrics
import Synchronization
import AsyncAlgorithms

/// A generic common implementation of file-based reloading for configuration providers.
///
/// This internal type handles all the common reloading logic, state management,
/// and service lifecycle for reloading file-based providers. It allows different provider types
/// (JSON, YAML, and so on) to reuse the same logic while providing their own format-specific deserialization.
internal final class ReloadingFileProviderCore<SnapshotType: ConfigSnapshotProtocol>: Sendable {

    /// The internal storage structure for the provider state.
    private struct Storage {

        /// The current configuration snapshot.
        var snapshot: SnapshotType

        /// Last modified timestamp of the resolved file.
        var lastModifiedTimestamp: Date

        /// The resolved real file path.
        var realFilePath: FilePath

        /// Active watchers for individual configuration values, keyed by encoded key.
        var valueWatchers: [AbsoluteConfigKey: [UUID: AsyncStream<Result<LookupResult, any Error>>.Continuation]]

        /// Active watchers for configuration snapshots.
        var snapshotWatchers: [UUID: AsyncStream<SnapshotType>.Continuation]

        /// Returns the total number of active watchers.
        var totalWatcherCount: Int {
            let valueWatcherCount = valueWatchers.values.map(\.count).reduce(0, +)
            let snapshotWatcherCount = snapshotWatchers.count
            return valueWatcherCount + snapshotWatcherCount
        }
    }

    /// Internal provider storage.
    private let storage: Mutex<Storage>

    /// The file system interface for reading files and timestamps.
    private let fileSystem: any CommonProviderFileSystem

    /// The original unresolved file path provided by the user, may contain symlinks.
    private let filePath: FilePath

    /// The interval between polling checks.
    private let pollInterval: Duration

    /// The human-readable name of the provider.
    internal let providerName: String

    /// The logger for this provider instance.
    private let logger: Logger

    /// The metrics collector for this provider instance.
    private let metrics: ReloadingFileProviderMetrics

    /// The closure that creates a new snapshot from file data.
    private let createSnapshot: @Sendable (Data) async throws -> SnapshotType

    /// Creates a new reloading file provider core.
    ///
    /// This initializer performs the initial file load and snapshot creation,
    /// resolves any symlinks, and sets up the internal storage.
    ///
    /// - Parameters:
    ///   - filePath: The path to the configuration file to monitor.
    ///   - pollInterval: The interval between timestamp checks.
    ///   - providerName: The human-readable name of the provider.
    ///   - fileSystem: The file system to use.
    ///   - logger: The logger instance, or nil to create a default one.
    ///   - metrics: The metrics factory, or nil to use a no-op implementation.
    ///   - createSnapshot: A closure that creates a snapshot from file data.
    /// - Throws: If the initial file load or snapshot creation fails.
    internal init(
        filePath: FilePath,
        pollInterval: Duration,
        providerName: String,
        fileSystem: any CommonProviderFileSystem,
        logger: Logger?,
        metrics: (any MetricsFactory)?,
        createSnapshot: @Sendable @escaping (Data) async throws -> SnapshotType
    ) async throws {
        self.filePath = filePath
        self.pollInterval = pollInterval
        self.providerName = providerName
        self.fileSystem = fileSystem
        self.createSnapshot = createSnapshot

        // Set up the logger with metadata
        var logger = logger ?? Logger(label: providerName)
        logger[metadataKey: "\(providerName).filePath"] = .string(filePath.lastComponent?.string ?? "<nil>")
        logger[metadataKey: "\(providerName).pollInterval.seconds"] = .string(
            pollInterval.components.seconds.description
        )
        self.logger = logger

        // Set up metrics
        self.metrics = ReloadingFileProviderMetrics(
            factory: metrics ?? NOOPMetricsHandler.instance,
            providerName: providerName
        )

        // Perform initial load
        logger.debug("Performing initial file load")
        let realPath = try await fileSystem.resolveSymlinks(atPath: filePath)
        let data = try await fileSystem.fileContents(atPath: realPath)
        let initialSnapshot = try await createSnapshot(data)
        let timestamp = try await fileSystem.lastModifiedTimestamp(atPath: realPath)

        // Initialize storage
        self.storage = .init(
            .init(
                snapshot: initialSnapshot,
                lastModifiedTimestamp: timestamp,
                realFilePath: realPath,
                valueWatchers: [:],
                snapshotWatchers: [:]
            )
        )

        // Update initial metrics
        self.metrics.fileSize.record(data.count)

        logger.debug(
            "Successfully initialized reloading file provider core",
            metadata: [
                "\(providerName).realFilePath": .string(realPath.string),
                "\(providerName).initialTimestamp": .stringConvertible(timestamp.formatted(.iso8601)),
                "\(providerName).fileSize": .stringConvertible(data.count),
            ]
        )
    }

    /// Checks if the file has changed and reloads it if necessary.
    /// - Throws: File system errors or snapshot creation errors.
    /// - Parameter logger: The logger to use during the reload.
    internal func reloadIfNeeded(logger: Logger) async throws {
        logger.debug("reloadIfNeeded started")
        defer {
            logger.debug("reloadIfNeeded finished")
        }

        let candidateRealPath = try await fileSystem.resolveSymlinks(atPath: filePath)
        let candidateTimestamp = try await fileSystem.lastModifiedTimestamp(atPath: candidateRealPath)

        guard
            let (originalTimestamp, originalRealPath) =
                storage
                .withLock({ storage -> (Date, FilePath)? in
                    let originalTimestamp = storage.lastModifiedTimestamp
                    let originalRealPath = storage.realFilePath

                    // Check if either the real path or timestamp has changed
                    guard originalRealPath != candidateRealPath || originalTimestamp != candidateTimestamp else {
                        logger.debug(
                            "File path and timestamp unchanged, no reload needed",
                            metadata: [
                                "\(providerName).timestamp": .stringConvertible(originalTimestamp.formatted(.iso8601)),
                                "\(providerName).realPath": .string(originalRealPath.string),
                            ]
                        )
                        return nil
                    }
                    return (originalTimestamp, originalRealPath)
                })
        else {
            // No changes detected.
            return
        }

        logger.debug(
            "File path or timestamp changed, reloading...",
            metadata: [
                "\(providerName).originalTimestamp": .stringConvertible(originalTimestamp.formatted(.iso8601)),
                "\(providerName).candidateTimestamp": .stringConvertible(candidateTimestamp.formatted(.iso8601)),
                "\(providerName).originalRealPath": .string(originalRealPath.string),
                "\(providerName).candidateRealPath": .string(candidateRealPath.string),
            ]
        )

        // Load new data outside the lock
        let data = try await fileSystem.fileContents(atPath: candidateRealPath)
        let newSnapshot = try await createSnapshot(data)

        typealias ValueWatchers = [(
            AbsoluteConfigKey,
            Result<LookupResult, any Error>,
            [AsyncStream<Result<LookupResult, any Error>>.Continuation]
        )]
        typealias SnapshotWatchers = (SnapshotType, [AsyncStream<SnapshotType>.Continuation])
        guard
            let (valueWatchersToNotify, snapshotWatchersToNotify) =
                storage
                .withLock({ storage -> (ValueWatchers, SnapshotWatchers)? in

                    // Check if we lost the race with another caller
                    if storage.lastModifiedTimestamp != originalTimestamp || storage.realFilePath != originalRealPath {
                        return nil
                    }

                    // Update storage with new data
                    let oldSnapshot = storage.snapshot
                    storage.snapshot = newSnapshot
                    storage.lastModifiedTimestamp = candidateTimestamp
                    storage.realFilePath = candidateRealPath

                    logger.debug(
                        "Successfully reloaded file",
                        metadata: [
                            "\(providerName).timestamp": .stringConvertible(candidateTimestamp.formatted(.iso8601)),
                            "\(providerName).fileSize": .stringConvertible(data.count),
                            "\(providerName).realPath": .string(candidateRealPath.string),
                        ]
                    )

                    // Update metrics
                    metrics.reloadCounter.increment(by: 1)
                    metrics.fileSize.record(data.count)
                    metrics.watcherCount.record(storage.totalWatcherCount)

                    // Collect watchers to potentially notify outside the lock
                    let valueWatchers = storage.valueWatchers.compactMap {
                        (key, watchers) -> (
                            AbsoluteConfigKey,
                            Result<LookupResult, any Error>,
                            [AsyncStream<Result<LookupResult, any Error>>.Continuation]
                        )? in
                        guard !watchers.isEmpty else { return nil }

                        // Get old and new values for this key
                        let oldValue = Result { try oldSnapshot.value(forKey: key, type: .string) }
                        let newValue = Result { try newSnapshot.value(forKey: key, type: .string) }

                        let didChange =
                            switch (oldValue, newValue) {
                            case (.success(let lhs), .success(let rhs)):
                                lhs != rhs
                            case (.failure, .failure):
                                false
                            default:
                                true
                            }

                        // Only notify if the value changed
                        guard didChange else {
                            return nil
                        }
                        return (key, newValue, Array(watchers.values))
                    }

                    let snapshotWatchers = (newSnapshot, Array(storage.snapshotWatchers.values))
                    return (valueWatchers, snapshotWatchers)
                })
        else {
            logger.debug("Lost race with another caller, not modifying internal state")
            return
        }

        // Notify watchers outside the lock
        let totalWatchers = valueWatchersToNotify.map { $0.2.count }.reduce(0, +) + snapshotWatchersToNotify.1.count
        guard totalWatchers > 0 else {
            logger.debug("No watchers to notify")
            return
        }

        // Notify value watchers
        for (_, valueUpdate, watchers) in valueWatchersToNotify {
            for watcher in watchers {
                watcher.yield(valueUpdate)
            }
        }

        // Notify snapshot watchers
        for watcher in snapshotWatchersToNotify.1 {
            watcher.yield(snapshotWatchersToNotify.0)
        }

        logger.debug(
            "Notified watchers of file changes",
            metadata: [
                "\(providerName).valueWatcherKeys": .array(valueWatchersToNotify.map { .string($0.0.description) }),
                "\(providerName).snapshotWatcherCount": .stringConvertible(snapshotWatchersToNotify.1.count),
                "\(providerName).totalWatcherCount": .stringConvertible(totalWatchers),
            ]
        )
    }
}

extension ReloadingFileProviderCore: Service {
    internal func run() async throws {
        logger.debug("File polling starting")
        defer {
            logger.debug("File polling stopping")
        }

        var counter = 1
        for try await _ in AsyncTimerSequence(interval: pollInterval, clock: .continuous).cancelOnGracefulShutdown() {
            defer {
                counter += 1
                metrics.pollTickCounter.increment(by: 1)
            }

            var tickLogger = logger
            tickLogger[metadataKey: "\(providerName).poll.tick.number"] = .stringConvertible(counter)
            tickLogger.debug("Poll tick starting")
            defer {
                tickLogger.debug("Poll tick stopping")
            }

            do {
                try await reloadIfNeeded(logger: tickLogger)
            } catch {
                tickLogger.debug(
                    "Poll tick failed, will retry on next tick",
                    metadata: [
                        "error": "\(error)"
                    ]
                )
                metrics.pollTickErrorCounter.increment(by: 1)
            }
        }
    }
}

// MARK: - ConfigProvider-like implementation

extension ReloadingFileProviderCore: ConfigProvider {

    internal func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        try storage.withLock { storage in
            try storage.snapshot.value(forKey: key, type: type)
        }
    }

    internal func fetchValue(forKey key: AbsoluteConfigKey, type: ConfigType) async throws -> LookupResult {
        try await reloadIfNeeded(logger: logger)
        return try value(forKey: key, type: type)
    }

    internal func watchValue<Return>(
        forKey key: AbsoluteConfigKey,
        type: ConfigType,
        updatesHandler: (ConfigUpdatesAsyncSequence<Result<LookupResult, any Error>, Never>) async throws -> Return
    ) async throws -> Return {
        let (stream, continuation) = AsyncStream<Result<LookupResult, any Error>>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()

        // Add watcher and get initial value
        let initialValue: Result<LookupResult, any Error> = storage.withLock { storage in
            storage.valueWatchers[key, default: [:]][id] = continuation
            metrics.watcherCount.record(storage.totalWatcherCount)
            return .init {
                try storage.snapshot.value(forKey: key, type: type)
            }
        }
        defer {
            storage.withLock { storage in
                storage.valueWatchers[key, default: [:]][id] = nil
                metrics.watcherCount.record(storage.totalWatcherCount)
            }
        }

        // Send initial value
        continuation.yield(initialValue)
        return try await updatesHandler(.init(stream))
    }

    internal func snapshot() -> any ConfigSnapshotProtocol {
        storage.withLock { $0.snapshot }
    }

    internal func watchSnapshot<Return>(
        updatesHandler: (ConfigUpdatesAsyncSequence<any ConfigSnapshotProtocol, Never>) async throws -> Return
    ) async throws -> Return {
        let (stream, continuation) = AsyncStream<SnapshotType>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()

        // Add watcher and get initial snapshot
        let initialSnapshot = storage.withLock { storage in
            storage.snapshotWatchers[id] = continuation
            metrics.watcherCount.record(storage.totalWatcherCount)
            return storage.snapshot
        }
        defer {
            // Clean up watcher
            storage.withLock { storage in
                storage.snapshotWatchers[id] = nil
                metrics.watcherCount.record(storage.totalWatcherCount)
            }
        }

        // Send initial snapshot
        continuation.yield(initialSnapshot)
        return try await updatesHandler(.init(stream.map { $0 }))
    }
}

#endif

#if ReloadingSupport

#if canImport(FoundationEssentials)
import FoundationEssentials
#endif
import Metrics

/// Metrics for reloading file providers.
///
/// This type provides standardized metrics for file-based providers that support hot reloading.
internal struct ReloadingFileProviderMetrics {

    /// Counter for poll tick operations.
    ///
    /// This counter increments each time the provider checks the file's timestamp
    /// during its polling cycle, regardless of whether a reload was needed.
    let pollTickCounter: Counter

    /// Counter for poll tick errors.
    ///
    /// This counter increments when timestamp checking fails due to file system
    /// errors, permission issues, or other problems during polling.
    let pollTickErrorCounter: Counter

    /// Counter for successful reload operations.
    ///
    /// This counter increments each time the provider successfully reloads and
    /// parses the configuration file after detecting changes.
    let reloadCounter: Counter

    /// Counter for reload operation errors.
    ///
    /// This counter increments when file reloading fails due to parsing errors,
    /// file system issues, or other problems during the reload process.
    let reloadErrorCounter: Counter

    /// Gauge for current file size in bytes.
    ///
    /// This gauge tracks the size of the configuration file and is updated
    /// after each successful reload operation.
    let fileSize: Gauge

    /// Gauge for active watcher count.
    ///
    /// This gauge tracks the total number of active value and snapshot watchers
    /// currently registered with the provider.
    let watcherCount: Gauge

    /// Creates metrics for a reloading file provider.
    ///
    /// The metrics are created with standardized labels that include the provider
    /// name to distinguish between different provider types (JSON, YAML, and so on.)
    ///
    /// - Parameters:
    ///   - factory: The metrics factory to use for creating metric instances.
    ///   - providerName: The name of the provider. For example: "ReloadingJSONProvider".
    init(factory: any MetricsFactory, providerName: String) {
        let prefix = providerName.lowercased()
        self.pollTickCounter = Counter(label: "\(prefix)_poll_ticks_total", factory: factory)
        self.pollTickErrorCounter = Counter(label: "\(prefix)_poll_errors_total", factory: factory)
        self.reloadCounter = Counter(label: "\(prefix)_reloads_total", factory: factory)
        self.reloadErrorCounter = Counter(label: "\(prefix)_reload_errors_total", factory: factory)
        self.fileSize = Gauge(label: "\(prefix)_file_size_bytes", factory: factory)
        self.watcherCount = Gauge(label: "\(prefix)_watchers_active", factory: factory)
    }
}

#endif
