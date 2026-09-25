import SwiftUI

/// More → Subject colours: every subject on your schedule and homework, with
/// the colour it has, and the rest of Apple's colours to choose from.
struct SubjectColorsScreen: View {
    @EnvironmentObject private var session: LectioSession
    @State private var open: String?

    private struct Subject: Identifiable {
        var id: String { key }
        let key: String
        /// One of Lectio's own team names for it, e.g. "1j ma".
        let sample: String
    }

    /// Everything the app has seen: this and nearby weeks' lessons, and the
    /// homework list. Private events and codeless tiles are left out.
    private var subjects: [Subject] {
        var samples: [String: String] = [:]
        var codes: [String] = []
        for week in session.snapshot.weeks.values {
            for day in week.days {
                for lesson in day.lessons where !lesson.isPrivateEvent {
                    codes.append(lesson.code)
                }
            }
        }
        codes += session.snapshot.workItems.map { $0.code }
        for code in codes {
            guard let key = SubjectPalette.subjectKey(code), samples[key] == nil else { continue }
            samples[key] = code
        }
        return samples
            .map { Subject(key: $0.key, sample: $0.value) }
            .sorted {
                SubjectNames.name(forKey: $0.key)
                    .localizedStandardCompare(SubjectNames.name(forKey: $1.key)) == .orderedAscending
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Subject colours")
                        .font(.system(size: 26, weight: .bold))
                    Text("The colour on each lesson's stripe and dot. The first seven are the easiest to tell apart.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if subjects.isEmpty {
                    EmptyNotice(icon: "paintpalette", text: "No subjects loaded yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(subjects.enumerated()), id: \.element.id) { index, subject in
                            if index > 0 { Divider().padding(.leading, 50) }
                            row(subject)
                        }
                    }
                    .contentCard()
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background { AppBackground() }
        .sensoryFeedback(.selection, trigger: SubjectColors.shared.picked)
    }

    private func row(_ subject: Subject) -> some View {
        let current = SubjectPalette.choice(forKey: subject.key)
        let isOpen = open == subject.key
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { open = isOpen ? nil : subject.key }
            } label: {
                HStack(spacing: 13) {
                    Circle()
                        .fill(current.color)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SubjectNames.name(forKey: subject.key))
                            .font(.system(size: 16.5, weight: .medium))
                        Text(subject.sample.uppercased())
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(current.name)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                swatches(for: subject.key, current: current)
                    .padding(.horizontal, 15)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }

    private func swatches(for key: String, current: SubjectColorChoice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7),
                      spacing: 10) {
                ForEach(SubjectColorChoice.allCases) { choice in
                    Button {
                        SubjectColors.shared.set(choice, for: key)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(choice.color)
                                .frame(width: 32, height: 32)
                            if choice == current {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        // 44-point target around each 32-point swatch.
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.name)
                    .accessibilityAddTraits(choice == current ? .isSelected : [])
                }
            }
            if SubjectColors.shared.picked[key] != nil {
                Button("Back to automatic") {
                    SubjectColors.shared.set(nil, for: key)
                }
                .font(.system(size: 15, weight: .medium))
            }
        }
    }
}
