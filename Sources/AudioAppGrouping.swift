import Darwin
import Foundation

struct AudioProcessOwnerResolution: Equatable {
    let bundleID: String?
    let method: String
}

struct AudioProcessAttribution: Equatable {
    let pid: pid_t
    let processBundleID: String?
    let ownerBundleID: String?
    let method: String

    var diagnosticText: String {
        "pid=\(pid):\(processBundleID ?? "unknown")->\(ownerBundleID ?? "unresolved")[\(method)]"
    }
}

struct AudioSourceOrderEntry: Equatable {
    let id: String
    let hasCoreAudioClient: Bool
    let isProducingAudio: Bool
}

func orderedAudioSourceIDs(_ entries: [AudioSourceOrderEntry]) -> [String] {
    entries.sorted { lhs, rhs in
        let lhsPriority = lhs.isProducingAudio ? 0 : (lhs.hasCoreAudioClient ? 1 : 2)
        let rhsPriority = rhs.isProducingAudio ? 0 : (rhs.hasCoreAudioClient ? 1 : 2)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }.map(\.id)
}

/// Groups a recognized child-process bundle ID only when its owner bundle ID is
/// known among visible applications. It deliberately never strips an unknown
/// suffix such as `com.apple.WebKit.GPU` to guess an owner.
func groupedAudioAppBundleID(_ bundleID: String?, knownBundleIDs: Set<String>) -> String? {
    guard let bundleID, !bundleID.isEmpty else { return nil }
    let helperKinds: Set<String> = [
        "helper", "renderer", "gpu", "webcontent", "webprocess", "plugin",
        "networking", "network", "utility", "xpc", "service", "extension", "app-shim"
    ]
    let roots = knownBundleIDs.filter { root in
        guard let rootTail = root.split(separator: ".").last,
              !helperKinds.contains(rootTail.lowercased()),
              bundleID.hasPrefix(root + ".") else { return false }
        let suffix = bundleID.dropFirst(root.count + 1).split(separator: ".")
        guard let first = suffix.first else { return false }
        return helperKinds.contains(first.lowercased())
    }
    return roots.max(by: { $0.count < $1.count })
}

func resolveAudioProcessOwner(
    processPID: pid_t,
    processBundleID: String?,
    visibleAppBundleIDsByPID: [pid_t: String],
    visibleAppBundleIDs: Set<String>,
    parentPIDForProcess: (pid_t) -> pid_t?
) -> AudioProcessOwnerResolution {
    if let owner = visibleAppBundleIDsByPID[processPID] {
        return AudioProcessOwnerResolution(bundleID: owner, method: "app-pid")
    }

    var currentPID = processPID
    var visited = Set<pid_t>()
    for _ in 0..<16 {
        guard let parentPID = parentPIDForProcess(currentPID),
              parentPID > 1,
              parentPID != currentPID,
              visited.insert(parentPID).inserted else { break }
        if let owner = visibleAppBundleIDsByPID[parentPID] {
            return AudioProcessOwnerResolution(bundleID: owner, method: "parent-pid:\(parentPID)")
        }
        currentPID = parentPID
    }

    guard let processBundleID, !processBundleID.isEmpty else {
        return AudioProcessOwnerResolution(bundleID: nil, method: "pid-only")
    }
    if visibleAppBundleIDs.contains(processBundleID) {
        return AudioProcessOwnerResolution(bundleID: processBundleID, method: "visible-bundle-id")
    }
    if let owner = groupedAudioAppBundleID(processBundleID, knownBundleIDs: visibleAppBundleIDs) {
        return AudioProcessOwnerResolution(bundleID: owner, method: "visible-bundle-prefix")
    }
    return AudioProcessOwnerResolution(bundleID: processBundleID, method: "unresolved-bundle-id")
}

func audioProcessGroupKey(
    processPID: pid_t,
    processBundleID: String?,
    ownerBundleID: String?,
    method: String
) -> String {
    if method == "unresolved-bundle-id", processBundleID?.hasPrefix("com.apple.WebKit.") == true {
        return "pid-\(processPID)"
    }
    return ownerBundleID ?? "pid-\(processPID)"
}
