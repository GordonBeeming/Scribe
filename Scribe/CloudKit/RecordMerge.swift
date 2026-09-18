import Foundation
import CloudKit

/// Field-level reconciliation for a record two devices edited at once.
///
/// Whole-record last-writer-wins loses data whenever the two edits touched different fields:
/// the loser's change is simply gone, and whose clock is fast decides which one. With the
/// last-synced record cached locally we have a common ancestor, so each key can be resolved
/// on its own and only genuine same-key collisions fall back to a timestamp.
enum RecordMerge {
    /// Result of reconciling one record. `record` is a copy of the server record with the merged
    /// field values written into it, so it carries the server's change tag; `differsFromServer`
    /// is true when at least one key ended up with a value other than the server's, i.e. a
    /// re-push is needed.
    struct Outcome {
        let record: CKRecord
        let differsFromServer: Bool
    }

    private static let modifiedAtKey = "modifiedAt"

    /// Whether a record can serve as a merge ancestor. A cache written before records were archived
    /// whole decodes to system fields only, which says nothing about which side changed what.
    static func hasUsableAncestor(_ record: CKRecord?) -> Bool {
        guard let record else { return false }
        return !record.allKeys().isEmpty
    }

    /// Merge `client` (this device's copy) and `server` (the copy CloudKit holds) against the
    /// `ancestor` both diverged from. The merged values go into a copy; `server` itself is left
    /// untouched so the caller can cache it as the ancestor for the next merge, which has to be
    /// what the server actually holds rather than what we hope it will hold.
    static func threeWay(ancestor: CKRecord?, client: CKRecord, server: CKRecord) -> Outcome {
        // A copy that fails is treated as "no client key won", so the server's copy stands and
        // nothing is dropped quietly. RecordMerge has no logger; the caller logs the outcome.
        guard let merged = server.copy() as? CKRecord else {
            return Outcome(record: server, differsFromServer: false)
        }

        let clientModified = client.object(forKey: modifiedAtKey) as? Date ?? .distantPast
        let serverModified = server.object(forKey: modifiedAtKey) as? Date ?? .distantPast

        var keys = Set(client.allKeys())
        keys.formUnion(server.allKeys())
        if let ancestor {
            keys.formUnion(ancestor.allKeys())
        }
        keys.remove(modifiedAtKey)

        // Without a usable ancestor there is nothing to diff against, so those records get the old
        // whole-record rule until the next successful sync writes a real one.
        let usableAncestor: CKRecord? = hasUsableAncestor(ancestor) ? ancestor : nil

        var clientWonAKey = false

        for key in keys {
            let clientValue = client.object(forKey: key)
            let serverValue = server.object(forKey: key)

            // Keeping the server's value is the default: it covers "neither side changed this
            // key", "only the server changed it", and every tie.
            var winner = serverValue
            if let usableAncestor {
                let ancestorValue = usableAncestor.object(forKey: key)
                let clientChanged = !valuesEqual(clientValue, ancestorValue)
                let serverChanged = !valuesEqual(serverValue, ancestorValue)
                if clientChanged {
                    // Both moved the same field to different values, so one has to give. The
                    // record whose last edit is newer wins the key. `modifiedAt` is record-level,
                    // so this is not "whoever changed this field later" — we can't know that
                    // without a timestamp per field, which would mean a new column on every model
                    // for a tie-break this rare. Record-level keeps it deterministic on every
                    // device, and a tie below keeps the server.
                    let clientWinsCollision = clientModified > serverModified
                        && !valuesEqual(clientValue, serverValue)
                    if !serverChanged || clientWinsCollision {
                        winner = clientValue
                    }
                }
            } else if clientModified > serverModified {
                winner = clientValue
            }

            guard !valuesEqual(winner, serverValue) else { continue }
            merged.setObject(winner, forKey: key)
            clientWonAKey = true
        }

        if clientWonAKey {
            let newest = max(clientModified, serverModified)
            merged.setObject(newest as NSDate, forKey: modifiedAtKey)
        }

        return Outcome(record: merged, differsFromServer: clientWonAKey)
    }

    /// CKRecord values are all Foundation objects (NSString, NSNumber, NSDate, NSArray,
    /// CKRecord.Reference, CKAsset), so `isEqual:` is the right comparison; a missing key is
    /// equal only to another missing key.
    private static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs else { return rhs == nil }
        guard let rhs else { return false }
        guard let lhsObject = lhs as? NSObject, let rhsObject = rhs as? NSObject else {
            return false
        }
        return lhsObject.isEqual(rhsObject)
    }
}
