#if canImport(CloudKit)
import CloudKit
import Foundation

/// Sharing the keywords with another Apple ID: the owner's side (a zone-wide
/// `CKShare` of the "Keywords" zone only) and the accepting side.
///
/// The share is saved with a direct modify call on the private database, not
/// through the `CKSyncEngine`: the system sharing sheet needs the saved share
/// before it can show, and the engine sends later and in batches. The engine
/// still sees the share record come back as an ordinary change in its zone
/// and ignores it (its handlers only take `ItemKeywords`). The Household zone
/// is never shared, never touched here, and `CKShare` has no records of its
/// own to leak: a zone-wide share exposes this zone's records and nothing else.
public struct KeywordShare: Sendable {
    public enum Status: Sendable, Equatable {
        /// No share yet (or it was stopped).
        case notShared
        /// Shared; `people` have been invited or have accepted.
        case shared(people: Int)
    }

    public static let title = "Matiné"

    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { CloudKitKeywordCloud.zoneID }

    public init(container id: String = PrivateCloudEngine.containerIdentifier) {
        container = CKContainer(identifier: id)
    }

    /// The existing zone share, nil if there is none.
    public func existingShare() async throws -> CKShare? {
        do {
            return try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    public func status() async throws -> Status {
        guard let share = try await existingShare() else { return .notShared }
        return .shared(people: Self.people(in: share))
    }

    /// The participants other than the owner who haven't been removed.
    public static func people(in share: CKShare) -> Int {
        share.participants.filter { $0.role != .owner && $0.acceptanceStatus != .removed }.count
    }

    /// The share to present: the existing one, or a new zone-wide one. Anyone invited gets
    /// read and write; nobody can join from the link alone (`publicPermission = .none`).
    public func shareToPresent() async throws -> (share: CKShare, container: CKContainer) {
        if let share = try await existingShare() { return (share, container) }
        // The zone may not exist yet on a phone that never made keywords.
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = Self.title
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        if let (_, outcome) = result.saveResults.first, case .failure(let error) = outcome {
            // Another device made the share first: present that one.
            if let ck = error as? CKError, ck.code == .serverRecordChanged, let existing = try await existingShare() { return (existing, container) }
            throw error
        }
        return (share, container)
    }

    /// Accepts a share the system handed to the app (the link was opened). Only a share of
    /// the Keywords zone is accepted; anything else is refused, whatever its source.
    /// Returns false, having done nothing, when the owner opened their own link.
    @discardableResult
    public static func accept(_ metadata: CKShare.Metadata, container id: String = PrivateCloudEngine.containerIdentifier) async throws -> Bool {
        guard metadata.containerIdentifier == id,
              metadata.share.recordID.recordName == CKRecordNameZoneWideShare,
              metadata.share.recordID.zoneID.zoneName == CloudKitKeywordCloud.zoneID.zoneName
        else { throw KeywordShareError.notKeywords }
        if metadata.participantRole == .owner { return false }
        _ = try await CKContainer(identifier: id).accept(metadata)
        return true
    }
}

public enum KeywordShareError: Error, Sendable { case notKeywords }
#endif
