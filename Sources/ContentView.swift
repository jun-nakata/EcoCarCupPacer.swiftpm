import SwiftUI

struct ContentView: View {
    @State private var pomodoro = PomodoroTimer()
    @State private var showingPicker = false

    var body: some View {
        ZStack {
            phaseBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                    .padding(.top, 60)

                Spacer()

                donutChart
                    .padding(.horizontal, 40)

                Spacer()

                controlButton
                    .padding(.bottom, 52)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: pomodoro.phase)
        .confirmationDialog(
            "セッション数を選択",
            isPresented: $showingPicker,
            titleVisibility: .visible
        ) {
            ForEach(1...5, id: \.self) { n in
                Button("\(n)セッション（約\(n * 30)分）") {
                    pomodoro.start(sessions: n)
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerView: some View {
        if pomodoro.phase == .idle {
            VStack(spacing: 6) {
                Text("ポモドーロタイマー")
                    .font(.title2.bold())
                Text("25分集中・5分休憩のサイクル")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 10) {
                Text(phaseLabel)
                    .font(.title2.bold())
                    .foregroundStyle(accentColor)
                sessionDots
            }
        }
    }

    private var sessionDots: some View {
        HStack(spacing: 10) {
            ForEach(1...pomodoro.totalSessions, id: \.self) { i in
                Circle()
                    .fill(i <= pomodoro.currentSession ? accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .animation(.spring, value: pomodoro.currentSession)
            }
        }
    }

    private var donutChart: some View {
        ZStack {
            // Track ring
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 30)

            // Progress ring
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(
                    accentColor,
                    style: StrokeStyle(lineWidth: 30, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: pomodoro.remainingSeconds)

            // Center
            centerContent
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        VStack(spacing: 8) {
            switch pomodoro.phase {
            case .idle:
                Image(systemName: "timer")
                    .font(.system(size: 54))
                    .foregroundStyle(.secondary)

            case .work, .shortBreak:
                Text(pomodoro.timeString)
                    .font(.system(size: 60, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                    .animation(.none, value: pomodoro.timeString)
                Text(pomodoro.phase == .work ? "作業中" : "休憩中")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("完了！")
                    .font(.title.bold())
            }
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        switch pomodoro.phase {
        case .idle, .complete:
            Button {
                showingPicker = true
            } label: {
                Text(pomodoro.phase == .complete ? "もう一度" : "開始")
                    .font(.title3.bold())
                    .frame(width: 200, height: 56)
                    .background(accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }

        case .work, .shortBreak:
            Button {
                pomodoro.reset()
            } label: {
                Text("リセット")
                    .font(.title3.bold())
                    .frame(width: 200, height: 56)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundStyle(.primary)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Helpers

    private var ringProgress: Double {
        switch pomodoro.phase {
        case .idle:    return 1.0
        case .complete: return 0.0
        default:       return pomodoro.progress
        }
    }

    private var accentColor: Color {
        switch pomodoro.phase {
        case .idle:       return .blue
        case .work:       return .orange
        case .shortBreak: return .teal
        case .complete:   return .green
        }
    }

    private var phaseBackground: Color {
        switch pomodoro.phase {
        case .idle, .complete: return Color(.systemBackground)
        case .work:            return .orange.opacity(0.04)
        case .shortBreak:      return .teal.opacity(0.04)
        }
    }

    private var phaseLabel: String {
        switch pomodoro.phase {
        case .idle:       return "待機中"
        case .work:       return "作業 \(pomodoro.currentSession) / \(pomodoro.totalSessions)"
        case .shortBreak: return "休憩 \(pomodoro.currentSession) / \(pomodoro.totalSessions)"
        case .complete:   return "完了"
        }
    }
}
