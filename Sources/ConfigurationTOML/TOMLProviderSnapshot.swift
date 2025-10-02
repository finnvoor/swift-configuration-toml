import Configuration
import SystemPackage
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A snapshot of configuration values parsed from TOML data.
///
/// This structure represents a point-in-time view of configuration values. It handles
/// the conversion from TOML types to configuration value types.
internal struct TOMLProviderSnapshot {
    /// The key encoder for TOML.
    static let keyEncoder: SeparatorKeyEncoder = .dotSeparated

    /// A parsed TOML value compatible with the config system.
    enum TOMLValue: CustomStringConvertible {

        /// A string value.
        case string(String)

        /// An integer value.
        case integer(Int)

        /// A floating point value.
        case float(Double)

        /// A boolean value.
        case boolean(Bool)

        /// A string array.
        case stringArray([String])

        /// An integer array.
        case integerArray([Int])

        /// A float array.
        case floatArray([Double])

        /// A boolean array.
        case booleanArray([Bool])

        var description: String {
            switch self {
            case .string(let string):
                return "\(string)"
            case .integer(let int):
                return "\(int)"
            case .float(let float):
                return "\(float)"
            case .boolean(let bool):
                return "\(bool)"
            case .stringArray(let strings):
                return strings.joined(separator: ",")
            case .integerArray(let ints):
                return ints.map(String.init).joined(separator: ",")
            case .floatArray(let floats):
                return floats.map { String($0) }.joined(separator: ",")
            case .booleanArray(let bools):
                return bools.map(String.init).joined(separator: ",")
            }
        }
    }

    /// A wrapper of a TOML value with the information of whether it's secret.
    internal struct ValueWrapper: CustomStringConvertible {

        /// The underlying TOML value.
        var value: TOMLValue

        /// Whether it should be treated as secret and not logged in plain text.
        var isSecret: Bool

        var description: String {
            if isSecret {
                return "<REDACTED>"
            }
            return "\(value)"
        }
    }

    /// The internal TOML provider error type.
    internal enum TOMLConfigError: Error, CustomStringConvertible {

        /// The TOML parsing failed.
        case parsingFailed(FilePath, String)

        /// A TOML key is not convertible to string.
        case keyNotConvertibleToString([String])

        /// The TOML primitive type is not supported.
        case unsupportedPrimitiveValue([String])

        /// Detected an array with a heterogeneous type, which isn't supported.
        case unexpectedValueInArray([String], Int)

        /// Invalid TOML syntax.
        case invalidSyntax(String)

        var description: String {
            switch self {
            case .parsingFailed(let path, let reason):
                return "TOML parsing failed for file: \(path). Reason: \(reason)"
            case .keyNotConvertibleToString(let keyPath):
                return "TOML key is not convertible to string: \(keyPath.joined(separator: "."))"
            case .unsupportedPrimitiveValue(let keyPath):
                return "Unsupported primitive value at \(keyPath.joined(separator: "."))"
            case .unexpectedValueInArray(let keyPath, let index):
                return "Unexpected value in array at \(keyPath.joined(separator: ".")) at index: \(index)."
            case .invalidSyntax(let reason):
                return "Invalid TOML syntax: \(reason)"
            }
        }
    }

    /// A decoder of bytes from a string.
    var bytesDecoder: any ConfigBytesFromStringDecoder

    /// The underlying config values.
    var values: [String: ValueWrapper]

    /// Creates a snapshot with pre-parsed values.
    ///
    /// - Parameters:
    ///   - values: The configuration values.
    ///   - bytesDecoder: The decoder for converting string values to bytes.
    init(
        values: [String: ValueWrapper],
        bytesDecoder: some ConfigBytesFromStringDecoder
    ) {
        self.values = values
        self.bytesDecoder = bytesDecoder
    }

    /// Creates a snapshot by parsing TOML data from a file.
    ///
    /// This initializer reads TOML data from the specified file, parses it using
    /// a built-in TOML parser, and converts the parsed values into the internal
    /// configuration format. The top-level TOML value must be a table.
    ///
    /// - Parameters:
    ///   - filePath: The path of the TOML file to read.
    ///   - fileSystem: The file system interface for reading the file.
    ///   - bytesDecoder: The decoder for converting string values to bytes.
    ///   - secretsSpecifier: The specifier for identifying secret values.
    /// - Throws: An error if the TOML root is not a table, or any error from
    ///   file reading or TOML parsing.
    init(
        filePath: FilePath,
        fileSystem: some CommonProviderFileSystem,
        bytesDecoder: some ConfigBytesFromStringDecoder,
        secretsSpecifier: SecretsSpecifier<String, Void>
    ) async throws {
        let fileContents = try await fileSystem.fileContents(atPath: filePath)
        guard let contentString = String(data: fileContents, encoding: .utf8) else {
            throw TOMLProviderSnapshot.TOMLConfigError.parsingFailed(filePath, "File is not valid UTF-8")
        }
        
        let parsedTable = try TOMLParser.parse(contentString)
        let values = try parseValues(
            parsedTable,
            keyEncoder: Self.keyEncoder,
            secretsSpecifier: secretsSpecifier
        )
        
        self.init(
            values: values,
            bytesDecoder: bytesDecoder
        )
    }

    /// Parses config content from the provided TOML value.
    /// - Parameters:
    ///   - valueWrapper: The wrapped TOML value.
    ///   - key: The config key.
    ///   - type: The config type.
    /// - Returns: The parsed config value.
    /// - Throws: If the value cannot be parsed.
    private func parseValue(
        _ valueWrapper: ValueWrapper,
        key: AbsoluteConfigKey,
        type: ConfigType
    ) throws -> ConfigValue {
        func throwMismatch() throws -> Never {
            throw ConfigError.configValueNotConvertible(name: key.description, type: type)
        }

        let value = valueWrapper.value
        let content: ConfigContent
        switch type {
        case .string:
            guard case .string(let string) = value else {
                try throwMismatch()
            }
            content = .string(string)
        case .int:
            guard case .integer(let int) = value else {
                try throwMismatch()
            }
            content = .int(int)
        case .double:
            switch value {
            case .float(let double):
                content = .double(double)
            case .integer(let int):
                content = .double(Double(int))
            default:
                try throwMismatch()
            }
        case .bool:
            guard case .boolean(let bool) = value else {
                try throwMismatch()
            }
            content = .bool(bool)
        case .bytes:
            guard
                case .string(let string) = value,
                let bytesValue = bytesDecoder.decode(string)
            else {
                try throwMismatch()
            }
            content = .bytes(bytesValue)
        case .stringArray:
            guard case .stringArray(let array) = value else {
                try throwMismatch()
            }
            content = .stringArray(array)
        case .intArray:
            guard case .integerArray(let array) = value else {
                try throwMismatch()
            }
            content = .intArray(array)
        case .doubleArray:
            switch value {
            case .floatArray(let array):
                content = .doubleArray(array)
            case .integerArray(let intArray):
                content = .doubleArray(intArray.map(Double.init))
            default:
                try throwMismatch()
            }
        case .boolArray:
            guard case .booleanArray(let array) = value else {
                try throwMismatch()
            }
            content = .boolArray(array)
        case .byteChunkArray:
            guard case .stringArray(let array) = value else {
                try throwMismatch()
            }
            let byteChunkArray = try array.map { stringValue in
                guard let bytesValue = bytesDecoder.decode(stringValue) else {
                    try throwMismatch()
                }
                return bytesValue
            }
            content = .byteChunkArray(byteChunkArray)
        }
        return ConfigValue(content, isSecret: valueWrapper.isSecret)
    }
}

extension TOMLProviderSnapshot: ConfigSnapshotProtocol {
    var providerName: String {
        "TOMLProvider"
    }

    // swift-format-ignore: AllPublicDeclarationsHaveDocumentation
    func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        let encodedKey = Self.keyEncoder.encode(key)
        return try withConfigValueLookup(encodedKey: encodedKey) {
            guard let value = values[encodedKey] else {
                return nil
            }
            return try parseValue(value, key: key, type: type)
        }
    }
}

/// A basic TOML parser that supports the subset of TOML needed for configuration.
internal enum TOMLParser {
    
    /// Parse a TOML document into a table (dictionary) format.
    static func parse(_ content: String) throws -> [String: Any] {
        let parser = Parser(content: content)
        return try parser.parse()
    }
    
    /// Internal TOML parser implementation.
    private class Parser {
        private let lines: [String]
        private var currentLineIndex = 0
        private var currentSection: [String] = []
        
        init(content: String) {
            self.lines = content.components(separatedBy: .newlines)
        }
        
        func parse() throws -> [String: Any] {
            var result: [String: Any] = [:]
            
            while currentLineIndex < lines.count {
                let line = lines[currentLineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                currentLineIndex += 1
                
                // Skip empty lines and comments
                if line.isEmpty || line.hasPrefix("#") {
                    continue
                }
                
                // Handle section headers
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    let sectionName = String(line.dropFirst().dropLast())
                    currentSection = sectionName.components(separatedBy: ".")
                    continue
                }
                
                // Handle key-value pairs
                if let equalIndex = line.firstIndex(of: "=") {
                    let keyPart = String(line.prefix(upTo: equalIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let valuePart = String(line.suffix(from: line.index(after: equalIndex))).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    let fullKey = (currentSection + [keyPart]).joined(separator: ".")
                    let value = try parseValue(valuePart)
                    
                    setNestedValue(&result, key: fullKey, value: value)
                }
            }
            
            return result
        }
        
        private func parseValue(_ valueString: String) throws -> Any {
            let trimmed = valueString.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Handle arrays
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let arrayContent = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if arrayContent.isEmpty {
                    return [String]()  // Empty array defaults to string array
                }
                
                let elements = try parseArrayElements(arrayContent)
                return elements
            }
            
            // Handle strings (quoted)
            if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
               (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
                return String(trimmed.dropFirst().dropLast())
            }
            
            // Handle booleans
            if trimmed.lowercased() == "true" {
                return true
            }
            if trimmed.lowercased() == "false" {
                return false
            }
            
            // Handle numbers
            if let intValue = Int(trimmed) {
                return intValue
            }
            
            if let doubleValue = Double(trimmed) {
                return doubleValue
            }
            
            // Treat unquoted values as strings (basic TOML strings)
            return trimmed
        }
        
        private func parseArrayElements(_ content: String) throws -> [Any] {
            var elements: [Any] = []
            var current = ""
            var inQuotes = false
            var quoteChar: Character? = nil
            
            for char in content {
                if !inQuotes && (char == "\"" || char == "'") {
                    inQuotes = true
                    quoteChar = char
                    current.append(char)
                } else if inQuotes && char == quoteChar {
                    inQuotes = false
                    current.append(char)
                    quoteChar = nil
                } else if !inQuotes && char == "," {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        elements.append(try parseValue(current))
                    }
                    current = ""
                } else {
                    current.append(char)
                }
            }
            
            // Add the last element
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                elements.append(try parseValue(current))
            }
            
            return elements
        }
        
        private func setNestedValue(_ dict: inout [String: Any], key: String, value: Any) {
            let keys = key.components(separatedBy: ".")
            setNestedValueRecursive(&dict, keys: keys, value: value)
        }
        
        private func setNestedValueRecursive(_ dict: inout [String: Any], keys: [String], value: Any) {
            guard !keys.isEmpty else { return }
            
            let key = keys[0]
            if keys.count == 1 {
                // Last key, set the value
                dict[key] = value
            } else {
                // Intermediate key, ensure there's a dictionary and recurse
                if dict[key] == nil {
                    dict[key] = [String: Any]()
                }
                if var nestedDict = dict[key] as? [String: Any] {
                    setNestedValueRecursive(&nestedDict, keys: Array(keys.dropFirst()), value: value)
                    dict[key] = nestedDict
                }
            }
        }
    }
}

/// Parses the parsed TOML table into configuration values.
/// - Parameters:
///   - parsedTable: The parsed TOML table.
///   - keyEncoder: The key encoder.
///   - secretsSpecifier: The secrets specifier.
/// - Throws: When parsing fails.
/// - Returns: The parsed and validated TOML config values.
internal func parseValues(
    _ parsedTable: [String: Any],
    keyEncoder: some ConfigKeyEncoder,
    secretsSpecifier: SecretsSpecifier<String, Void>
) throws -> [String: TOMLProviderSnapshot.ValueWrapper] {
    var values: [String: TOMLProviderSnapshot.ValueWrapper] = [:]
    var valuesToIterate: [([String], Any)] = parsedTable.map { ([$0], $1) }
    
    while !valuesToIterate.isEmpty {
        let (keyComponents, value) = valuesToIterate.removeFirst()
        
        if let dictionary = value as? [String: Any] {
            valuesToIterate.append(contentsOf: dictionary.map { (keyComponents + [$0], $1) })
        } else {
            let tomlValue: TOMLProviderSnapshot.TOMLValue
            
            if let array = value as? [Any] {
                // Determine array type from first element
                if array.isEmpty {
                    tomlValue = .stringArray([])  // Default empty arrays to string
                } else {
                    let firstElement = array[0]
                    if firstElement is String {
                        let stringArray = try array.enumerated().map { index, element in
                            guard let string = element as? String else {
                                throw TOMLProviderSnapshot.TOMLConfigError.unexpectedValueInArray(keyComponents, index)
                            }
                            return string
                        }
                        tomlValue = .stringArray(stringArray)
                    } else if firstElement is Int {
                        let intArray = try array.enumerated().map { index, element in
                            guard let int = element as? Int else {
                                throw TOMLProviderSnapshot.TOMLConfigError.unexpectedValueInArray(keyComponents, index)
                            }
                            return int
                        }
                        tomlValue = .integerArray(intArray)
                    } else if firstElement is Double {
                        let floatArray = try array.enumerated().map { index, element in
                            guard let double = element as? Double else {
                                throw TOMLProviderSnapshot.TOMLConfigError.unexpectedValueInArray(keyComponents, index)
                            }
                            return double
                        }
                        tomlValue = .floatArray(floatArray)
                    } else if firstElement is Bool {
                        let boolArray = try array.enumerated().map { index, element in
                            guard let bool = element as? Bool else {
                                throw TOMLProviderSnapshot.TOMLConfigError.unexpectedValueInArray(keyComponents, index)
                            }
                            return bool
                        }
                        tomlValue = .booleanArray(boolArray)
                    } else {
                        throw TOMLProviderSnapshot.TOMLConfigError.unsupportedPrimitiveValue(keyComponents)
                    }
                }
            } else if let string = value as? String {
                tomlValue = .string(string)
            } else if let int = value as? Int {
                tomlValue = .integer(int)
            } else if let double = value as? Double {
                tomlValue = .float(double)
            } else if let bool = value as? Bool {
                tomlValue = .boolean(bool)
            } else {
                throw TOMLProviderSnapshot.TOMLConfigError.unsupportedPrimitiveValue(keyComponents)
            }
            
            let encodedKey = keyEncoder.encode(AbsoluteConfigKey(keyComponents))
            let isSecret = secretsSpecifier.isSecret(key: encodedKey, value: ())
            values[encodedKey] = .init(value: tomlValue, isSecret: isSecret)
        }
    }
    
    return values
}
