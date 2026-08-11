//
//  DateUtils.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation

struct DateUtils {
    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// `MM:SS` under an hour — where the rest countdown and a normal workout
    /// both live — and `H:MM:SS` from an hour up, so a long session reads as
    /// `5:04:46` instead of the unreadable `304:46`. The sub-hour form is
    /// byte-for-byte what it always was, so the Runner's timer is unaffected.
    static func formatDuration(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        guard hours > 0 else {
            return String(format: "%02d:%02d", minutes, secs)
        }
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }

    static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
