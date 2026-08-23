//
//  AppTab.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  The four things the app is *for*, in the order someone reaches for them.
//
//  The previous set — 今日 / ワークアウト / 履歴 / 設定 — mixed two different
//  kinds of thing. Training and Nutrition are what a user comes back to every
//  day; History and Settings are places you visit *because of* one of those,
//  which is a different job. Giving them equal billing spent two of four slots
//  on destinations nobody opens the app to reach, and left Nutrition — a daily
//  module — with no home of its own at all.
//
//  So the primary tabs are now the daily modules plus the two frames around
//  them: Home to see where you stand, and Me for everything about you and the
//  app. History moved under Training, Settings under Me. Neither screen
//  changed; only how you get there.
//
//  Four, deliberately. Every additional tab makes the others slower to find,
//  and Gym, Machines, Form Guide, AI and Recovery are all reachable from
//  inside the module they belong to.
//

import Foundation

enum AppTab: Hashable, CaseIterable {
    /// Where the user stands today.
    case home
    /// Routines, and the workout history behind them.
    case training
    /// Meals and intake.
    case nutrition
    /// The user, their profile, and app settings.
    case me
}
