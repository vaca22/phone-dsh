// SPDX-License-Identifier: MIT
import Foundation

/// A single relative change to the iPhone's current media/output volume.
public enum TonoLinkVolumeDirection: Sendable, Equatable {
    case up
    case down
}

/// Narrow, model-free voice routing for commands that have a safe one-step meaning.
/// Unknown or compound requests remain with the normal chat/UI agent path.
public enum TonoLinkVolumeIntent {
    private static let volumeUp: Set<String> = [
        "调大音量", "把音量调大", "帮我把音量调大", "增大音量", "提高音量", "调高音量",
        "音量调大一点", "音量调高一点", "音量大一点", "声音调大一点", "声音大一点", "大一点声", "大点声",
        "volumeup", "turnupthevolume", "increasevolume",
    ]
    private static let volumeDown: Set<String> = [
        "调小音量", "把音量调小", "帮我把音量调小", "减小音量", "降低音量", "调低音量",
        "音量调小一点", "音量调低一点", "音量小一点", "声音调小一点", "声音小一点", "小一点声", "小点声",
        "volumedown", "turndownthevolume", "decreasevolume",
    ]

    /// Matches only standalone, unambiguous relative volume requests. It intentionally does not
    /// interpret percentages, mute, ringer/Silent-mode wording, or compound requests.
    public static func direction(for text: String) -> TonoLinkVolumeDirection? {
        var normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for wake in ["你好小智", "小智"] where normalized.hasPrefix(wake) {
            normalized.removeFirst(wake.count)
            break
        }
        normalized = String(normalized.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        })
        if volumeUp.contains(normalized) { return .up }
        if volumeDown.contains(normalized) { return .down }
        return nil
    }
}
