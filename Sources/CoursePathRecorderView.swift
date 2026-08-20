import SwiftUI
import CoreLocation

/// 実際に走行して走行ライン（コースパス）を記録する画面。
/// コントロールラインが未設定でも使える。保存すると、コントロールラインまでの残り距離が
/// 直線距離ではなくこの経路に沿った距離で計算されるようになる。
/// コントロールラインは記録とは独立して保存されるので、この記録を使ったあとでも
/// 「今コントロールラインを通過」でいつでも上書き・修正できる。
struct CoursePathRecorderView: View {
    var pacer: LapPacer
    var locationManager: LocationManager

    @Environment(\.dismiss) private var dismiss

    @State private var isRecording = false
    @State private var recordedPoints: [CoursePoint] = []
    @State private var startDate: Date?
    @State private var initialCourse: Double?
    @State private var previousLocation: CLLocation?
    @State private var totalDistance: Double = 0
    @State private var showingDiscardConfirmation = false
    @State private var showingSetControlLinePrompt = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)

                statsSection

                Spacer(minLength: 0)

                actionSection

                Text("コントロールラインを通過する瞬間に「記録開始」をタップし、1周走ってコントロールラインに戻ってきたら「記録終了」をタップしてください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle("走行ラインを走って記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        if isRecording {
                            showingDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: locationManager.lastLocation?.timestamp) {
                appendIfNeeded()
            }
            .confirmationDialog(
                "記録中です。破棄して閉じますか？",
                isPresented: $showingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("破棄して閉じる", role: .destructive) {
                    isRecording = false
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("コントロールラインも設定しますか？", isPresented: $showingSetControlLinePrompt) {
                Button("この記録の開始点に設定する") {
                    setControlLineFromFirstPoint()
                    dismiss()
                }
                Button("あとで設定する", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text("コントロールラインが未設定です。この記録の開始点を、進行方向つきでコントロールラインとして設定できます。設定画面からいつでも修正できます。")
            }
        }
    }

    // MARK: - 状態表示

    @ViewBuilder
    private var statsSection: some View {
        if isRecording {
            VStack(spacing: 8) {
                Text(durationText)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                Text(String(format: "%.0f m ・ %d点", totalDistance, recordedPoints.count))
                    .foregroundStyle(.secondary)
                Label("記録中", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } else if recordedPoints.count > 1 {
            VStack(spacing: 8) {
                Text("記録完了")
                    .font(.title3.bold())
                Text(String(format: "%.0f m ・ %@ ・ %d点", totalDistance, durationText, recordedPoints.count))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "location.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(locationManager.lastLocation == nil ? "GPSの位置情報を取得中です…" : "準備完了")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var durationText: String {
        let elapsed = recordedPoints.last?.elapsedSeconds ?? 0
        let m = Int(elapsed) / 60
        let s = Int(elapsed) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - 操作ボタン

    @ViewBuilder
    private var actionSection: some View {
        if isRecording {
            Button(role: .destructive) {
                stopRecording()
            } label: {
                Label("記録終了", systemImage: "stop.circle.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else if recordedPoints.count > 1 {
            VStack(spacing: 12) {
                Button("この記録を走行ラインとして保存") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button("破棄してやり直す", role: .destructive) {
                    reset()
                }
            }
        } else {
            Button {
                startRecording()
            } label: {
                Label("記録開始", systemImage: "record.circle")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(locationManager.lastLocation == nil)
        }
    }

    // MARK: - 記録ロジック

    private func startRecording() {
        guard let location = locationManager.lastLocation else { return }
        isRecording = true
        startDate = location.timestamp
        initialCourse = location.course >= 0 ? location.course : nil
        previousLocation = location
        totalDistance = 0
        recordedPoints = [CoursePoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, elapsedSeconds: 0)]
    }

    private func appendIfNeeded() {
        guard isRecording, let location = locationManager.lastLocation, let startDate else { return }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 50 else { return }
        if let prev = previousLocation {
            let delta = location.distance(from: prev)
            guard delta > 1.0 else { return }
            totalDistance += delta
        }
        let elapsed = location.timestamp.timeIntervalSince(startDate)
        recordedPoints.append(CoursePoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, elapsedSeconds: elapsed))
        previousLocation = location
    }

    private func stopRecording() {
        isRecording = false
    }

    private func reset() {
        recordedPoints = []
        totalDistance = 0
        startDate = nil
        initialCourse = nil
        previousLocation = nil
    }

    private func save() {
        pacer.setCoursePath(CoursePath(points: recordedPoints))
        if pacer.controlLine == nil {
            showingSetControlLinePrompt = true
        } else {
            dismiss()
        }
    }

    private func setControlLineFromFirstPoint() {
        guard let first = recordedPoints.first else { return }
        let heading: Double
        if let initialCourse {
            heading = initialCourse
        } else if recordedPoints.count > 1 {
            heading = Self.bearing(from: first.coordinate, to: recordedPoints[1].coordinate)
        } else {
            heading = 0
        }
        pacer.setControlLine(latitude: first.latitude, longitude: first.longitude, headingDegrees: heading)
    }

    /// 2点間の初期方位（真北から時計回り、度）
    private static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearingDegrees = atan2(y, x) * 180 / .pi
        return (bearingDegrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
