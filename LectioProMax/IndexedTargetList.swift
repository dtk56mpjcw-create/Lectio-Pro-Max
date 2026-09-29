import SwiftUI

/// A long list of people, grouped by first letter with a scrub strip down the
/// side — the group hand-in's classmate picker (GroupMemberPicker). Find a
/// schedule has the system's own list and letter index instead
/// (FindScheduleScreen).
struct IndexedTargetList: View {
    let targets: [ScheduleTarget]
    var showsIndex: Bool = true
    var onSelect: (ScheduleTarget) -> Void

    /// Grouped in whatever order the locale sorted them — so Æ, Ø and Å land
    /// after Z on a Danish phone without special-casing.
    private var sections: [(letter: String, items: [ScheduleTarget])] {
        let sorted = targets.sorted {
            $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending
        }
        var order: [String] = []
        var buckets: [String: [ScheduleTarget]] = [:]
        for target in sorted {
            let letter = target.indexLetter
            if buckets[letter] == nil {
                order.append(letter)
                buckets[letter] = []
            }
            buckets[letter]?.append(target)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var indexVisible: Bool { showsIndex && sections.count > 2 }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(sections, id: \.letter) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.letter)
                                    .scaledFont(size: 12.5, weight: .heavy)
                                    .tracking(0.7)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                                VStack(spacing: 0) {
                                    ForEach(section.items) { row($0) }
                                }
                                .contentCard(radius: Metrics.inner)
                            }
                            .id(section.letter)
                        }
                    }
                    .padding(.trailing, indexVisible ? 30 : 0)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)

                if indexVisible {
                    AlphabetIndex(letters: sections.map { $0.letter }) { letter in
                        // No animation: while a thumb is sliding down the strip,
                        // animating every jump lands behind the finger. Instant
                        // is what makes it feel attached to the touch.
                        proxy.scrollTo(letter, anchor: .top)
                    }
                }
            }
        }
    }

    private func row(_ target: ScheduleTarget) -> some View {
        Button { onSelect(target) } label: {
            HStack(spacing: 10) {
                // A face for people, an icon for everything else — a room has
                // no photo and a class is not a person.
                if target.contextCardID != nil {
                    PersonAvatar(target: target)
                } else {
                    Image(systemName: target.kind.icon)
                        .scaledFont(size: 13.5, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.sortName)
                        .scaledFont(size: 15.5)
                        .multilineTextAlignment(.leading)
                    if let klasse = target.studentClass {
                        Text(klasse)
                            .scaledFont(size: 12.5, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The letter strip down the right-hand edge, the way Apple's own long lists
/// work: tap a letter, or slide a thumb down it to scrub.
struct AlphabetIndex: View {
    let letters: [String]
    var onSelect: (String) -> Void

    @State private var active: String?
    @State private var activeY: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .scaledFont(size: 10.5, weight: .semibold)
                        .foregroundStyle(active == letter ? Palette.accent : Color(.secondaryLabel))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // A wider target than the letters themselves, so the strip is
            // catchable without aiming.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let step = geometry.size.height / CGFloat(max(letters.count, 1))
                        let index = min(max(Int(value.location.y / step), 0), letters.count - 1)
                        activeY = (CGFloat(index) + 0.5) * step
                        let letter = letters[index]
                        if letter != active {
                            active = letter
                            onSelect(letter)
                        }
                    }
                    .onEnded { _ in active = nil }
            )
            // An OVERLAY, deliberately: putting the bubble in the layout made
            // the strip as wide as the bubble and pushed the letters off screen.
            .overlay(alignment: .top) {
                if let active = active {
                    Text(active)
                        .scaledFont(size: 25, weight: .bold)
                        .foregroundStyle(.primary)
                        .frame(width: 58, height: 58)
                        .contentCard(radius: 29)
                        .offset(x: -48, y: activeY - 29)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 26)
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: active)
    }
}
