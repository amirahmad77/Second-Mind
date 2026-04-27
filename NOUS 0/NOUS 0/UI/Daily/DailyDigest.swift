import Foundation

/// Pure-function picker for the Daily strip surface. Three slots:
///   - "On this day" — atom from exactly N years ago (1y first, fall back to 2y…7y)
///   - "Random" — uniform random non-deleted atom (excludes anything captured today)
///   - "Slow read" — entry point, doesn't pick an atom (full vault is fair game)
///
/// Pure / deterministic-given-seed so the digest is stable through a session
/// (re-render = same picks). Re-rolls on next calendar day OR on manual refresh.
enum DailyDigest {

    struct Picks: Equatable {
        var onThisDay: AtomSnapshot?
        var random: AtomSnapshot?
        /// The day this digest was computed for. Stream re-runs digest when day changes.
        var day: Date
    }

    /// Compute today's picks. `now` injectable for testability.
    @MainActor
    static func compute(from atoms: [AtomSnapshot], now: Date = .now, calendar: Calendar = .current) -> Picks {
        let day = calendar.startOfDay(for: now)
        let live = atoms.filter { !$0.isDeleted }

        return Picks(
            onThisDay: pickOnThisDay(from: live, now: now, calendar: calendar),
            random: pickRandom(from: live, excludingDay: day, calendar: calendar),
            day: day
        )
    }

    // MARK: - On this day

    /// Walk back year by year (1…7). For each year, pick the most-recent atom that
    /// falls on the same calendar day-of-year. Ignore future years (only past).
    private static func pickOnThisDay(from atoms: [AtomSnapshot], now: Date, calendar: Calendar) -> AtomSnapshot? {
        let today = calendar.dateComponents([.month, .day], from: now)
        let nowYear = calendar.component(.year, from: now)

        for yearsBack in 1...7 {
            let targetYear = nowYear - yearsBack
            // Find atoms whose (year, month, day) match (targetYear, today.month, today.day).
            let matches = atoms.filter { atom in
                let comps = calendar.dateComponents([.year, .month, .day], from: atom.createdAt)
                return comps.year == targetYear
                    && comps.month == today.month
                    && comps.day == today.day
            }
            if let pick = matches.sorted(by: { $0.createdAt > $1.createdAt }).first {
                return pick
            }
        }
        return nil
    }

    // MARK: - Random

    /// Uniform random pick. Excludes today and yesterday — both are visible in the
    /// stream above, so surfacing them in the random card adds no value.
    private static func pickRandom(from atoms: [AtomSnapshot], excludingDay: Date, calendar: Calendar) -> AtomSnapshot? {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: excludingDay) ?? excludingDay
        let pool = atoms.filter {
            let day = calendar.startOfDay(for: $0.createdAt)
            return day != excludingDay && day != yesterday
        }
        return pool.randomElement()
    }
}
