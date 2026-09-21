import Foundation
import AppKit
import SwiftUI

// MARK: - Database location

struct TCCDatabaseFile: Identifiable, Hashable {
    enum Kind: String { case system = "System", user = "User" }
    let url: URL
    let kind: Kind
    var id: String { url.path }
    var writableByUs: Bool { kind == .user }
}

// MARK: - Record

struct TCCRecord: Identifiable, Hashable {
    let db: TCCDatabaseFile
    let service: String
    let client: String
    let clientType: Int            // 0 = identifier, 1 = path
    let authValue: Int             // 0 denied, 1 unknown, 2 allowed, 3 limited
    let authReason: Int
    let authVersion: Int
    let csreq: Data?
    let policyID: Int?
    let indirectObject: String     // 'UNUSED' or target identifier (Automation)
    let flags: Int
    let lastModified: Date
    let managed: Bool              // from managed_overrides table
    let adminAuthValue: Int?       // managed_overrides only

    var id: String {
        "\(db.id)|\(service)|\(client)|\(clientType)|\(indirectObject)|\(managed)"
    }

    var statusName: String {
        switch authValue {
        case 0: return "Denied"
        case 1: return "Unknown"
        case 2: return "Allowed"
        case 3: return "Limited"
        default: return "Other (\(authValue))"
        }
    }

    var statusColor: Color {
        switch authValue {
        case 0: return .red
        case 2: return .green
        case 3: return .orange
        default: return .gray
        }
    }

    var reasonName: String {
        switch authReason {
        case 0: return "None"
        case 1: return "Error"
        case 2: return "User Consent"
        case 3: return "User Set"
        case 4: return "System Set"
        case 5: return "Service Policy"
        case 6: return "MDM Policy"
        case 7: return "Override Policy"
        case 8: return "Missing Usage String"
        case 9: return "Prompt Timeout"
        case 10: return "Preflight Unknown"
        case 11: return "Entitled"
        case 12: return "App Type Policy"
        default: return "Reason \(authReason)"
        }
    }
}

// MARK: - Pending mutation (confirmation sheet payload)

struct PendingChange: Identifiable {
    enum Op: String {
        case grant = "Grant", revoke = "Revoke", reset = "Reset", delete = "Delete"
    }
    let id = UUID()
    let op: Op
    let service: String
    let client: String
    let clientType: Int
    let indirectObject: String
    let db: TCCDatabaseFile
    let csreq: Data?
    var summary: String {
        switch op {
        case .grant:  return "Allow \(client) → \(service)"
        case .revoke: return "Deny \(client) → \(service)"
        case .reset, .delete: return "Remove record: \(client) → \(service)"
        }
    }
}

// MARK: - Client identity (resolved app info)

struct ClientIdentity {
    let name: String
    let icon: NSImage
    let appURL: URL?
    let isPathClient: Bool
}
