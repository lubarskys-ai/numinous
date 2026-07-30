import Foundation
import NuminousCore

/// Turns a grounded `Observation` into a warm sentence. This is the swappable
/// "voice" layer — templated today, an on-device model later. Two rules keep it
/// trustworthy: every fact comes from the observation (never invented here), and
/// the tone stays gentle and noticing, never diagnostic ("I noticed…", not
/// "you're neglecting…").
enum ReflectionPhrasing {

    static func text(for observation: Observation, axes: [Axis],
                     notes: [Note], history: [ReflectionRecord]) -> String {
        let axisName: (String) -> String = { id in
            axes.first { $0.id == id }?.name ?? id.capitalized
        }
        let short: (String) -> String = { title in
            title.split(separator: "/").last.map(String.init) ?? title
        }
        // Stable per observation, so its wording doesn't flip each render.
        let variant = abs(observation.signature.hashValue)

        switch observation.kind {
        case .hub:
            let name = observation.noteTitles.first.map(short) ?? "someone"
            let count = Int(observation.magnitude)
            let callback = continuationPrefix(for: observation, axes: axes, history: history)
            let lines = [
                "\(name) has quietly become a crossroads in your life — \(count) threads meet there.",
                "So much of your web runs through \(name) now — \(count) connections and counting.",
            ]
            return callback + lines[variant % lines.count]

        case .firstBridge:
            let a = axisName(observation.axisIDs.first ?? "")
            let b = axisName(observation.axisIDs.dropFirst().first ?? "")
            let lines = [
                "Something new: your \(a) and \(b) just touched for the first time.",
                "A fresh thread — \(a) and \(b) are connected now where they weren't before.",
            ]
            return lines[variant % lines.count]

        case .momentum:
            let a = axisName(observation.axisIDs.first ?? "")
            let callback = continuationPrefix(for: observation, axes: axes, history: history)
            let lines = [
                "Lately you've been growing most in \(a). It shows.",
                "\(a) is where your life has been leaning — and it's flourishing.",
            ]
            return callback + lines[variant % lines.count]

        case .isolatedAxis:
            let a = axisName(observation.axisIDs.first ?? "")
            let lines = [
                "Your \(a) hasn't reached into the rest of your life yet — one [[link]] would change that.",
                "\(a) is growing on its own island. A single connection could bring it home.",
            ]
            return lines[variant % lines.count]

        case .quietAxis:
            let a = axisName(observation.axisIDs.first ?? "")
            let lines = [
                "\(a) has been quiet lately. It's still there, waiting for you.",
                "There's a hush around your \(a) these days — no rush, just noticing.",
            ]
            return lines[variant % lines.count]
        }
    }

    /// If this axis was flagged quiet/isolated before, open by acknowledging the
    /// change — the "it remembers me" feeling. Empty when there's no such history.
    private static func continuationPrefix(for observation: Observation, axes: [Axis],
                                           history: [ReflectionRecord]) -> String {
        guard let axisID = observation.axisIDs.first else { return "" }
        let name = axes.first { $0.id == axisID }?.name ?? axisID.capitalized
        let wasQuiet = history.contains {
            $0.signature == "quietAxis:\(axisID)" || $0.signature == "isolatedAxis:\(axisID)"
        }
        return wasQuiet ? "Last time your \(name) was quiet — it's stirring now. " : ""
    }
}
