//
//  NotificationManager.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import UserNotifications

@MainActor
protocol RunnerNotificationManaging: AnyObject {
    func getAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void)
    func scheduleRestNotification(
        deadline: Date,
        identifier: String,
        completion: @escaping () -> Void
    )
    func removeNotification(identifier: String)
}

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    private var requestGenerations: [String: Int] = [:]
    private var desiredRestRequests: [String: UNNotificationRequest] = [:]

    private init() {}

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    func getAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }

    func scheduleRestNotification(deadline: Date, identifier: String) {
        scheduleRestNotification(deadline: deadline, identifier: identifier, completion: {})
    }

    func scheduleRestNotification(
        deadline: Date,
        identifier: String,
        completion: @escaping () -> Void
    ) {
        let content = UNMutableNotificationContent()
        content.title = "休憩終了"
        content.body = "次のセットを開始しましょう。"
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: deadline
            ),
            repeats: false
        )

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        let generation = nextGeneration(for: identifier)
        desiredRestRequests[identifier] = request
        submit(request, generation: generation, completion: completion)
    }

    func removeNotification(identifier: String) {
        _ = nextGeneration(for: identifier)
        desiredRestRequests[identifier] = nil
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func removeAllPending() {
        for identifier in desiredRestRequests.keys {
            _ = nextGeneration(for: identifier)
        }
        desiredRestRequests.removeAll()
        center.removeAllPendingNotificationRequests()
    }

    private func nextGeneration(for identifier: String) -> Int {
        let generation = (requestGenerations[identifier] ?? 0) &+ 1
        requestGenerations[identifier] = generation
        return generation
    }

    private func submit(
        _ request: UNNotificationRequest,
        generation: Int,
        completion: @escaping () -> Void
    ) {
        let identifier = request.identifier
        center.add(request) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.requestGenerations[identifier] == generation,
                      self.desiredRestRequests[identifier] != nil
                else {
                    self.reconcile(identifier: identifier)
                    return
                }
                completion()
            }
        }
    }

    private func reconcile(identifier: String) {
        guard let request = desiredRestRequests[identifier] else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return
        }
        let generation = requestGenerations[identifier] ?? 0
        submit(request, generation: generation, completion: {})
    }
}

extension NotificationManager: RunnerNotificationManaging {}
