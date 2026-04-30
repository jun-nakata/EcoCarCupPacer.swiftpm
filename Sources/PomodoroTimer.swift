import Foundation
import Observation

enum PomodoroPhase {
    case idle, work, shortBreak, complete
}

@Observable
final class PomodoroTimer {
    private(set) var phase: PomodoroPhase = .idle
    private(set) var currentSession = 0
    private(set) var totalSessions = 0
    private(set) var remainingSeconds = 0

    private var ticker: Timer?

    static let workSeconds = 25 * 60
    static let breakSeconds = 5 * 60

    var progress: Double {
        let total = phase == .work ? Self.workSeconds : Self.breakSeconds
        guard total > 0 else { return 0 }
        return Double(remainingSeconds) / Double(total)
    }

    var timeString: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    func start(sessions: Int) {
        reset()
        totalSessions = sessions
        currentSession = 1
        beginWork()
    }

    func reset() {
        ticker?.invalidate()
        ticker = nil
        phase = .idle
        currentSession = 0
        totalSessions = 0
        remainingSeconds = 0
    }

    private func beginWork() {
        phase = .work
        remainingSeconds = Self.workSeconds
        scheduleTicker()
    }

    private func beginBreak() {
        phase = .shortBreak
        remainingSeconds = Self.breakSeconds
        scheduleTicker()
    }

    private func scheduleTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        remainingSeconds -= 1
        if remainingSeconds <= 0 {
            advance()
        }
    }

    private func advance() {
        ticker?.invalidate()
        ticker = nil
        switch phase {
        case .work:
            if currentSession < totalSessions {
                beginBreak()
            } else {
                phase = .complete
            }
        case .shortBreak:
            currentSession += 1
            beginWork()
        default:
            break
        }
    }
}
