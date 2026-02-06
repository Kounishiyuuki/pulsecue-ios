# PulseCue iOS - Testing Guide

This document provides a comprehensive testing checklist for the PulseCue iOS app.

## Build Verification

### Prerequisites
- Xcode 15.0 or later
- iOS 17.0+ device or simulator
- macOS with support for iOS development

### Build Steps
1. Open `PulseCue.xcodeproj` in Xcode
2. Select target device (iOS 17+ simulator or physical device)
3. Build (⌘B) - should complete without errors
4. Run (⌘R) - app should launch successfully

### Expected Build Output
- No compilation errors
- No warnings (or minimal warnings)
- App launches to the Today tab

## Feature Testing Checklist

### 1. Tab Navigation ✓
- [ ] All 4 tabs visible in tab bar
- [ ] Tab icons display correctly
- [ ] Tapping each tab navigates correctly
- [ ] Tab labels are readable

### 2. Today Tab
#### Health Display
- [ ] "Today's Health" card displays
- [ ] All metrics show with proper labels (Intake, Exercise, Balance, Sleep, Weight)
- [ ] Balance calculation is correct (Intake - Exercise)
- [ ] Balance color is green when positive, red when negative
- [ ] "Update Log" button navigates to DayLog entry screen
- [ ] Empty state shows "No data logged today" when no log exists

#### Active Workout Display
- [ ] Shows "No active workout" when no workout running
- [ ] "Start Workout" button navigates to Workout tab
- [ ] When workout active, shows RunnerView component
- [ ] Runner state persists across app restarts

### 3. Workout Tab
#### Routine List
- [ ] Search bar is functional
- [ ] Search filters routines by name (case-insensitive)
- [ ] Pinned routines appear in separate section
- [ ] Pin icon (📌) displays for pinned routines
- [ ] Step count displays correctly for each routine
- [ ] "+" button in toolbar creates new routine

#### Routine Actions
- [ ] Swipe left reveals Pin/Unpin and Duplicate actions
- [ ] Swipe right reveals Delete action
- [ ] Long press shows context menu
- [ ] Context menu options work: Start Workout, Pin/Unpin, Duplicate, Delete
- [ ] Delete shows confirmation dialog
- [ ] Duplicate creates copy with "(Copy)" suffix
- [ ] Duplicated routine has all steps copied

#### Routine Creation/Editing
- [ ] Tapping routine navigates to edit screen
- [ ] Routine name is editable
- [ ] Steps list displays correctly
- [ ] "Add Step" button opens step editor
- [ ] Step editor allows name and duration input
- [ ] Duration stepper increments by 5 seconds
- [ ] Steps can be reordered by dragging (in Edit mode)
- [ ] Steps can be deleted by swiping left
- [ ] Save button persists changes
- [ ] Cancel button discards changes

### 4. Runner (Workout Execution)
#### Display
- [ ] Routine name displays at top
- [ ] NOW section shows current step
- [ ] NOW section highlights during rest period
- [ ] Countdown timer displays in MM:SS format
- [ ] Countdown updates every second
- [ ] REST indicator appears during rest
- [ ] NEXT section shows upcoming step
- [ ] NEXT section shows "Complete!" when on last step

#### Actions
- [ ] "Start" button initiates timer for current step
- [ ] "Complete" button advances to next step
- [ ] "Skip" button skips current step
- [ ] "+10s" button adds 10 seconds to timer
- [ ] "+10s" disabled when not in rest mode
- [ ] "Back" button returns to previous step
- [ ] "Back" disabled on first step
- [ ] "Stop Workout" button ends workout and returns to idle

#### State Persistence
- [ ] Kill app during workout and relaunch
- [ ] Runner state should restore correctly
- [ ] Timer should continue from correct time
- [ ] Current step should be preserved

### 5. History Tab
#### Display
- [ ] Recent logs display in reverse chronological order
- [ ] Each log shows date, intake, exercise, balance, sleep, weight
- [ ] Balance color matches sign (green/red)
- [ ] Weight only shows if recorded
- [ ] Logs are scrollable
- [ ] Shows last 30 days of entries

### 6. DayLog Entry
#### Input
- [ ] All fields are editable
- [ ] Numeric keyboards appear for number fields
- [ ] Balance calculates automatically as you type
- [ ] Balance updates in real-time
- [ ] Weight field is optional (can be left empty)
- [ ] Cancel button discards changes
- [ ] Save button persists data

#### Data Persistence
- [ ] Saved data appears in Today tab
- [ ] Saved data appears in History tab
- [ ] Editing existing log updates values
- [ ] Multiple edits on same day update same log entry

### 7. Settings Tab
#### Beep Toggle
- [ ] Beep Sound toggle exists
- [ ] Toggle state persists across app restarts
- [ ] When enabled, beeps play during workout transitions
- [ ] When disabled, no beeps play

#### About Section
- [ ] Version displays correctly (1.0)
- [ ] Build number displays correctly (1)

#### Future Features
- [ ] All 5 future feature items are listed
- [ ] Tapping each shows "Coming Soon" placeholder
- [ ] Navigation works correctly

### 8. Cues and Feedback
#### Notifications
- [ ] App requests notification permission on first launch
- [ ] Notification scheduled when step timer starts
- [ ] Notification delivers when timer completes (if app in background)
- [ ] Notification shows correct step name
- [ ] Notification plays sound

#### Haptics
- [ ] Impact haptic on Start/Complete actions
- [ ] Success notification haptic on workout completion
- [ ] Light impact on +10s and Back
- [ ] Selection haptic on toggle changes
- [ ] Haptics work on physical device

#### Audio
- [ ] Beep plays on step transitions (when enabled)
- [ ] Beep is system sound (consistent with iOS)
- [ ] No beep when toggle disabled

### 9. Data Integrity
#### SwiftData
- [ ] New routines persist after app restart
- [ ] Edited routines persist changes
- [ ] Deleted routines are removed permanently
- [ ] Step order persists correctly
- [ ] DayLog entries persist correctly
- [ ] Multiple days of logs can coexist

#### UserDefaults
- [ ] Runner state saves on each significant change
- [ ] Beep preference persists
- [ ] State clears properly on workout completion

### 10. Error Handling
#### Edge Cases
- [ ] Creating routine with no steps doesn't crash
- [ ] Starting workout with empty routine handles gracefully
- [ ] Deleting currently running routine handles safely
- [ ] Invalid numeric input in DayLog doesn't crash
- [ ] Decimal input works for calories and weight
- [ ] Search with special characters doesn't crash

### 11. UI/UX
#### Visual
- [ ] All text is readable
- [ ] Colors follow iOS design guidelines
- [ ] Spacing and padding are consistent
- [ ] Cards and sections have proper shadows/borders
- [ ] Icons are appropriate and clear
- [ ] Dark mode support (if iOS system is in dark mode)

#### Accessibility
- [ ] VoiceOver reads all labels correctly
- [ ] All interactive elements are accessible
- [ ] Color contrast meets accessibility standards
- [ ] Dynamic type support (if text scales with system settings)

#### Performance
- [ ] App launches quickly (< 2 seconds)
- [ ] Navigation transitions are smooth
- [ ] No lag when scrolling lists
- [ ] Timer updates smoothly (no jitter)
- [ ] Memory usage is reasonable

## Known Limitations (by Design)

1. **No External Libraries**: App uses only native iOS frameworks
2. **Offline Only**: No cloud sync or remote data (future roadmap item)
3. **iOS 17+ Required**: Uses SwiftData which requires iOS 17+
4. **iPhone Only**: Optimized for portrait iPhone (iPad support could be added)
5. **No Apple Watch**: Companion app is a future roadmap item
6. **No HealthKit**: Integration is a future roadmap item
7. **Basic Audio**: Uses system beep sound only
8. **No Workout History**: Individual workout sessions aren't logged (only health metrics)

## Security Considerations

1. **Local Data Only**: All data stored locally in SwiftData
2. **No Authentication**: No user accounts or sensitive data
3. **Notifications**: Uses standard iOS notification permissions
4. **No Network Access**: App doesn't make network requests

## Performance Benchmarks

### Target Metrics
- App launch: < 2 seconds
- Navigation transition: < 0.3 seconds
- List scrolling: 60 FPS
- Timer update: 1 second precision (±0.05s)
- Memory usage: < 50 MB typical

### Testing on Different Devices
- iPhone 15 Pro (iOS 17)
- iPhone 14 (iOS 17)
- iPhone SE (3rd gen, iOS 17)
- Various iOS 17 simulators

## Regression Testing

After any code changes, verify:
1. All existing routines still load
2. Active workout state still persists
3. Health logs still display correctly
4. Settings preferences are preserved
5. No crashes on launch or during normal use

## Future Testing (for Roadmap Features)

### Phase 2: Authentication & Sync
- [ ] Sign in with Apple flow
- [ ] iCloud sync functionality
- [ ] Conflict resolution for multi-device

### Phase 3: HealthKit
- [ ] Import from HealthKit
- [ ] Export to HealthKit
- [ ] Permission handling

### Phase 4: AI & Nutrition
- [ ] AI recommendations
- [ ] Photo recognition
- [ ] Calorie estimation accuracy

### Phase 5: Widgets
- [ ] Home screen widget
- [ ] Lock screen widget
- [ ] Live Activities
- [ ] Dynamic Island

### Phase 6: Analytics
- [ ] Statistics calculations
- [ ] Charts rendering
- [ ] Data export

## Conclusion

This comprehensive testing guide ensures the PulseCue iOS app meets all specified requirements and provides a solid foundation for future enhancements.
