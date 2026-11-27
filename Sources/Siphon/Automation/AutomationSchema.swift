import Foundation

/// Versioned JSON Schema for the Automation API. CLI, REST, MCP and the remote
/// server all validate against this single document; contract tests assert the
/// schema, DTOs and MCP inputSchema stay in sync.
public enum AutomationSchema {
    public static let version = "1.0.0"

    public static let document: [String: Any] = [
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://siphon.local/schema/automation-v1.json",
        "title": "Siphon Automation API",
        "version": version,
        "type": "object",
        "definitions": [
            "add": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "format": "uri", "minLength": 1],
                    "dir": ["type": "string"],
                    "name": ["type": "string"],
                    "category": ["type": "string"],
                    "queue": ["type": "string"],
                    "checksum": ["type": "string"],
                    "later": ["type": "boolean"],
                ],
                "required": ["url"],
                "additionalProperties": false,
            ],
            "taskID": [
                "type": "object",
                "properties": ["id": ["type": "string", "format": "uuid"]],
                "required": ["id"],
                "additionalProperties": false,
            ],
            "listQuery": [
                "type": "object",
                "properties": [
                    "state": ["type": "string", "enum": ["queued", "downloading", "stopped", "complete", "error"]],
                    "queue": ["type": "string"],
                    "category": ["type": "string"],
                    "query": ["type": "string"],
                ],
                "additionalProperties": false,
            ],
            "torrentSelect": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "format": "uuid"],
                    "indexes": ["type": "array", "items": ["type": "integer", "minimum": 1]],
                ],
                "required": ["id", "indexes"],
                "additionalProperties": false,
            ],
            "torrentRename": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "format": "uuid"],
                    "index": ["type": "integer", "minimum": 1],
                    "newPath": ["type": "string", "minLength": 1],
                ],
                "required": ["id", "index", "newPath"],
                "additionalProperties": false,
            ],
            "speedLimit": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "format": "uuid"],
                    "bytesPerSec": ["type": "integer", "minimum": 0],
                ],
                "required": ["id", "bytesPerSec"],
                "additionalProperties": false,
            ],
        ],
    ]

    public static func schema(for command: String) -> [String: Any]? {
        let defs = document["definitions"] as? [String: Any]
        return defs?[command] as? [String: Any]
    }

    /// Lightweight runtime validator for the subset of JSON Schema used above.
    /// Returns nil on success, or a human-readable error message.
    public static func validate(_ value: Any, against schema: [String: Any], path: String = "") -> String? {
        guard let type = schema["type"] as? String else { return nil }
        switch type {
        case "object":
            guard let dict = value as? [String: Any] else { return "\(path) must be an object" }
            if let required = schema["required"] as? [String] {
                for key in required where dict[key] == nil {
                    return "\(path).\(key) is required"
                }
            }
            if schema["additionalProperties"] as? Bool == false,
               let props = schema["properties"] as? [String: Any] {
                for key in dict.keys where props[key] == nil {
                    return "\(path).\(key) is not allowed"
                }
            }
            if let props = schema["properties"] as? [String: Any] {
                for (key, sub) in props {
                    guard let subSchema = sub as? [String: Any], let val = dict[key] else { continue }
                    if let err = validate(val, against: subSchema, path: "\(path).\(key)") {
                        return err
                    }
                }
            }
        case "string":
            guard let s = value as? String else { return "\(path) must be a string" }
            if let min = schema["minLength"] as? Int, s.count < min {
                return "\(path) must be at least \(min) characters"
            }
            if let format = schema["format"] as? String {
                switch format {
                case "uri":
                    if URL(string: s) == nil { return "\(path) must be a valid URI" }
                case "uuid":
                    if UUID(uuidString: s) == nil { return "\(path) must be a valid UUID" }
                default: break
                }
            }
            if let enumVals = schema["enum"] as? [String], !enumVals.contains(s) {
                return "\(path) must be one of \(enumVals.joined(separator: ", "))"
            }
        case "integer":
            guard let n = value as? Int else { return "\(path) must be an integer" }
            if let min = schema["minimum"] as? Int, n < min {
                return "\(path) must be >= \(min)"
            }
        case "boolean":
            guard value is Bool else { return "\(path) must be a boolean" }
        case "array":
            guard let arr = value as? [Any] else { return "\(path) must be an array" }
            if let items = schema["items"] as? [String: Any] {
                for (i, item) in arr.enumerated() {
                    if let err = validate(item, against: items, path: "\(path)[\(i)]") {
                        return err
                    }
                }
            }
        default:
            break
        }
        return nil
    }
}
