import SwiftUI

/// The bell that sits on whatever it's reminding you about.
///
/// A reminder belongs to the thing itself, not to a switch in Settings — so it
/// lives on the row, and asks for notification permission the first time you
/// actually set one rather than up front.
struct ReminderButton: View {
    let itemKey: String
    /// False for things with no due date (absence), which get a plain on/off.
    var offersTiming: Bool = true
    var onChange: () -> Void

    @State private var timing: ReminderTiming?
    @State private var denied = false

    var body: some View {
        Group {
            if offersTiming {
                Menu {
                    ForEach(ReminderTiming.allCases, id: \.self) { option in
                        Button {
                            Task { await apply(option) }
                        } label: {
                            Label(option.label, systemImage: timing == option ? "checkmark" : option.icon)
                        }
                    }
                    if timing != nil {
                        Divider()
                        Button(role: .destructive) {
                            Task { await apply(nil) }
                        } label: {
                            Label("Remove reminder", systemImage: "bell.slash")
                        }
                    }
                } label: {
                    bell
                }
            } else {
                Button {
                    Task { await apply(timing == nil ? .morningOf : nil) }
                } label: {
                    bell
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { timing = RemindersStore.timing(for: itemKey) }
        // Felt as well as seen: a tap when a reminder is set or taken off.
        .sensoryFeedback(trigger: timing) { old, new in
            new == nil ? SensoryFeedback.impact(weight: .light) : SensoryFeedback.success
        }
        // If notifications are off for the app, setting a reminder used to do
        // nothing at all — the bell just stayed empty. Say why, and offer the
        // one place it can be fixed.
        .alert("Notifications are off", isPresented: $denied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("Reminders arrive as notifications. Turn them on for Lectio Pro Max in Settings.")
        }
    }

    private var bell: some View {
        Image(systemName: timing == nil ? "bell" : "bell.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(timing == nil ? Color(.tertiaryLabel) : Palette.accent)
            // The bell swaps outline for filled with the system's own symbol
            // animation, and rings once when a reminder is set.
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: timing != nil)
            // Laid out at 30 points as before; the target is Apple's 44.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .padding(-7)
            .accessibilityLabel(timing == nil ? "Set a reminder" : "Reminder set")
    }

    private func apply(_ option: ReminderTiming?) async {
        if option != nil {
            let granted = await NotificationService.requestPermission()
            guard granted else {
                denied = true
                return
            }
        }
        RemindersStore.set(option, for: itemKey)
        // Animated, so the bell fills with the symbol's own replace effect.
        withAnimation(.snappy) { timing = option }
        onChange()
    }
}
