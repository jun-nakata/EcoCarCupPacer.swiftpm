import SwiftUI
import CoreLocation

struct ContentView: View {
    @State private var locationManager = LocationManager()
    @State private var pacer = LapPacer()
    @State private var showingCalibration = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 20) {
                    remainingTimeHeader

                    Spacer(minLength: 0)

                    paceIndicator

                    Spacer(minLength: 0)

                    infoRow

                    if !pacer.laps.isEmpty {
                        lapHistory
                    }
                }
                .padding()
            }
            .navigationTitle("Eco Car Cup Pacer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCalibration = true
                    } label: {
                        Image(systemName: "flag.checkered.circle")
                            .font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showingCalibration) {
                CalibrationView(pacer: pacer, locationManager: locationManager)
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                locationManager.onLocationUpdate = { location in
                    pacer.ingest(location)
                }
                locationManager.requestAuthorization()
                locationManager.start()
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // MARK: - 残り時間

    private var remainingTimeHeader: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { context in
            let remaining = liveRemaining(at: context.date)
            VStack(spacing: 4) {
                Text("目標 \(formattedTarget) まで")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(remainingText(for: remaining))
                    .font(.system(size: 56, weight: .bold, design: .monospaced))
                    .foregroundStyle(remaining < 0 ? .red : .primary)
            }
        }
    }

    /// GPSの更新頻度に関わらず滑らかにカウントダウンさせるため、壁時計時刻から直接計算する。
    private func liveRemaining(at now: Date) -> Double {
        guard let start = pacer.lapStartDate else { return pacer.remainingToTarget }
        return pacer.targetLapSeconds - now.timeIntervalSince(start)
    }

    private func remainingText(for value: Double) -> String {
        let isOver = value < 0
        let a = abs(value)
        let m = Int(a) / 60
        let s = a - Double(m * 60)
        let base = String(format: "%d:%05.2f", m, s)
        return isOver ? "+\(base)" : base
    }

    private var formattedTarget: String {
        let m = Int(pacer.targetLapSeconds) / 60
        let s = Int(pacer.targetLapSeconds) % 60
        return String(format: "%d'%02d\"00", m, s)
    }

    // MARK: - ペース表示（上下矢印）

    @ViewBuilder
    private var paceIndicator: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(paceColor.opacity(0.15))
                    .frame(width: 220, height: 220)

                paceGlyph
            }
            .frame(width: 220, height: 220)

            Text(paceLabel)
                .font(.title2.bold())
                .foregroundStyle(paceColor)

            if let subtitle = paceSubtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 加速・減速時は、程度に応じてシェブロンの数と色の濃さを変えて段階的に表示する。
    @ViewBuilder
    private var paceGlyph: some View {
        switch pacer.paceState {
        case .speedUp:
            chevronStack(symbolName: "chevron.up")
        case .slowDown:
            chevronStack(symbolName: "chevron.down")
        case .notCalibrated, .waitingForData, .onPace:
            Image(systemName: paceSymbol)
                .font(.system(size: 96, weight: .bold))
                .foregroundStyle(paceColor)
        }
    }

    private func chevronStack(symbolName: String) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<paceTier, id: \.self) { _ in
                Image(systemName: symbolName)
                    .font(.system(size: 56, weight: .heavy))
            }
        }
        .foregroundStyle(paceColor.opacity(paceIntensity))
        .symbolEffect(.pulse, isActive: paceTier >= 3)
    }

    /// 加速・減速の見込み秒数を3段階に分け、矢印の数・濃さの根拠にする。
    private var paceTier: Int {
        switch pacer.paceState {
        case .speedUp(let seconds), .slowDown(let seconds):
            if seconds > 2.5 { return 3 }
            if seconds > 1.0 { return 2 }
            return 1
        default:
            return 0
        }
    }

    private var paceIntensity: Double {
        switch paceTier {
        case 1: return 0.5
        case 2: return 0.75
        default: return 1.0
        }
    }

    private var paceSymbol: String {
        switch pacer.paceState {
        case .notCalibrated: return "location.slash"
        case .waitingForData: return "hourglass"
        case .onPace: return "checkmark.circle.fill"
        case .speedUp: return "arrow.up.circle.fill"
        case .slowDown: return "arrow.down.circle.fill"
        }
    }

    private var paceColor: Color {
        switch pacer.paceState {
        case .notCalibrated: return .gray
        case .waitingForData: return .gray
        case .onPace: return .green
        case .speedUp: return .blue
        case .slowDown: return .red
        }
    }

    private var paceLabel: String {
        switch pacer.paceState {
        case .notCalibrated: return "未設定"
        case .waitingForData: return "計測中"
        case .onPace: return "このペースでOK"
        case .speedUp: return "加速"
        case .slowDown: return "減速"
        }
    }

    private var paceSubtitle: String? {
        switch pacer.paceState {
        case .notCalibrated:
            return "コントロールラインを設定してください"
        case .waitingForData:
            return "速度が上がるとペース判定が始まります"
        case .onPace:
            return nil
        case .speedUp(let seconds):
            return String(format: "このペースだと許容範囲より %.1f 秒遅れて到着する見込みです", clampedSeconds(seconds))
        case .slowDown(let seconds):
            return String(format: "このペースだと許容範囲より %.1f 秒早く到着する見込みです", clampedSeconds(seconds))
        }
    }

    private func clampedSeconds(_ seconds: Double) -> Double {
        min(seconds, 99.9)
    }

    // MARK: - 距離・速度

    private var infoRow: some View {
        HStack(spacing: 0) {
            infoTile(title: "ラインまで", value: distanceText, unit: "m")
            Divider().frame(height: 44)
            infoTile(title: "速度", value: speedText, unit: "km/h")
            Divider().frame(height: 44)
            infoTile(title: "GPS精度", value: accuracyText, unit: "m")
        }
    }

    private func infoTile(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.monospacedDigit().bold())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var distanceText: String {
        guard let d = pacer.distanceToLineMeters else { return "--" }
        return String(format: "%.0f", d)
    }

    private var speedText: String {
        guard let s = pacer.currentSpeedKmh else { return "--" }
        return String(format: "%.0f", s)
    }

    private var accuracyText: String {
        guard let a = pacer.horizontalAccuracy else { return "--" }
        return String(format: "±%.0f", a)
    }

    // MARK: - ラップ履歴

    private var lapHistory: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ラップ履歴")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(pacer.laps.prefix(8).enumerated()), id: \.element.id) { index, lap in
                        lapChip(number: pacer.laps.count - index, lap: lap)
                    }
                }
            }
        }
    }

    private func lapChip(number: Int, lap: LapRecord) -> some View {
        let delta = lap.duration - pacer.targetLapSeconds
        let m = Int(lap.duration) / 60
        let s = lap.duration - Double(m * 60)

        return VStack(spacing: 2) {
            Text("Lap \(number)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%d:%05.2f", m, s))
                .font(.callout.monospacedDigit().bold())
            Text(String(format: "%+.2f", delta))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(abs(delta) < 0.5 ? .green : (delta < 0 ? .red : .blue))
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
