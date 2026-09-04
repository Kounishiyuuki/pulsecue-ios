//
//  TrainingMoreView.swift
//  Pulse Cue
//
//  その他の機能 — the occasional training destinations, on a screen of their
//  own.
//
//  They used to be listed at the bottom of the Training root, below the
//  routine library. That reads fine with two routines and badly with twenty:
//  the library is unbounded, so the distance to My Gym or the machine
//  catalogue grew with the user's own history. Someone who used the app more
//  had a harder time reaching them, which is the wrong way round.
//
//  The rows themselves are unchanged — `TrainingMoreSection` still owns them,
//  and `TrainingSurface.moreDestinations` still decides which exist. Only
//  where they are shown moved.
//

import SwiftUI

struct TrainingMoreView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.deepSpace.opacity(0.95), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                TrainingMoreSection()
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
        }
        .navigationTitle("その他の機能")
        .navigationBarTitleDisplayMode(.large)
        .preferredColorScheme(.dark)
    }
}
