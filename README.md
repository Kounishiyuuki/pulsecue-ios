# PulseCue iOS

PulseCue is a comprehensive workout and health tracking app for iOS 17+, built entirely with SwiftUI and SwiftData. No external dependencies required—completely offline-first.

## Features

### ✅ Implemented

#### Workout Management
- **Four Main Tabs**: Today, Workout, History, Settings
- **Routine & Step CRUD**: Full create, read, update, delete functionality
- **Routine Operations**:
  - Reorder steps with drag & drop
  - Duplicate routines
  - Pin/unpin favorite routines
  - Search routines by name
- **Runner (Workout Execution)**:
  - Clean Now/Rest/Next UI display
  - Actions: Complete, Skip, +10 seconds, Back
  - Rest timer using deadline-based countdown
  - State persistence in UserDefaults for app kill/relaunch recovery
- **Cues & Feedback**:
  - Local notifications (scheduled for step completion)
  - In-app highlight during active step
  - Haptic feedback for all actions
  - Beep sound toggle in Settings

#### Health Tracking
- **DayLog System**:
  - Track daily calories intake
  - Track calories burned through exercise
  - Log sleep hours
  - Record weight (optional)
  - Automatic calorie balance calculation (intake - exercise)
- **History View**: Review past 30 days of health logs
- **Today View**: Quick summary of today's health metrics and active workout

#### Architecture
- **MVVM Pattern**: Clean separation between Views, ViewModels, and Models
- **SwiftData**: Native iOS persistence layer (iOS 17+)
- **Service Layer**: Modular services for notifications, haptics, audio, and persistence

### 🚧 Roadmap (Future Features)

#### Authentication & Sync
- [ ] Sign in with Apple integration
- [ ] iCloud sync for routines and health data across devices
- [ ] Multi-device state synchronization

#### HealthKit Integration
- [ ] Import exercise data from Apple Health
- [ ] Export workout sessions to HealthKit
- [ ] Sync weight and sleep data bidirectionally
- [ ] Heart rate monitoring during workouts

#### AI Coach & Nutrition
- [ ] AI-powered workout recommendations
- [ ] Meal photo recognition with calorie estimation
- [ ] Nutrition tracking and meal planning
- [ ] Progress analysis and insights

#### Widgets & Live Activities
- [ ] Home screen widgets for today's summary
- [ ] Lock screen widgets for quick glance
- [ ] Live Activities for ongoing workouts (Dynamic Island support)
- [ ] Complications for Apple Watch

#### Analytics & Insights
- [ ] Weekly/monthly workout statistics
- [ ] Progress charts and trends
- [ ] Achievement system and milestones
- [ ] Export data to CSV

#### Enhanced Features
- [ ] Apple Watch companion app
- [ ] Custom rest timer sounds
- [ ] Workout history and session logs
- [ ] Social sharing of achievements
- [ ] Dark mode optimizations

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## Architecture

```
PulseCue/
├── Models/              # SwiftData models
│   ├── Routine.swift
│   ├── Step.swift
│   └── DayLog.swift
├── ViewModels/          # Business logic
│   ├── RoutineViewModel.swift
│   ├── RunnerViewModel.swift
│   └── HealthViewModel.swift
├── Views/               # SwiftUI views
│   ├── TodayView.swift
│   ├── WorkoutView.swift
│   ├── HistoryView.swift
│   ├── SettingsView.swift
│   ├── RunnerView.swift
│   ├── RoutineListView.swift
│   ├── RoutineEditView.swift
│   └── DayLogView.swift
└── Services/            # Support services
    ├── NotificationService.swift
    ├── HapticService.swift
    ├── AudioService.swift
    └── PersistenceService.swift
```

## Building

1. Open `PulseCue.xcodeproj` in Xcode 15+
2. Select your target device or simulator (iOS 17+)
3. Build and run (⌘R)

## Usage

### Creating a Workout Routine
1. Go to the **Workout** tab
2. Tap the **+** button
3. Add a routine name and steps with durations
4. Save and start your workout

### Running a Workout
1. Select a routine from the **Workout** tab
2. Tap to start, or use the context menu
3. The runner shows: NOW (current step), REST (countdown), NEXT (upcoming step)
4. Use Complete/Skip/+10s/Back buttons to control progression
5. App preserves state if killed—relaunch continues where you left off

### Tracking Health
1. Go to the **Today** tab
2. Tap **Update Log**
3. Enter calories (intake/exercise), sleep hours, and weight
4. Balance is calculated automatically
5. View history in the **History** tab

## License

MIT License - see LICENSE file for details

## Contributing

Contributions welcome! Please feel free to submit a Pull Request.
