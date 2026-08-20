import SwiftUI
import CoreLocation

struct CalibrationView: View {
    @Bindable var pacer: LapPacer
    var locationManager: LocationManager

    @Environment(\.dismiss) private var dismiss
    @State private var showingResetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("コントロールラインを通過する瞬間にボタンをタップすると、現在地と進行方向がラインとして記録されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        if let location = locationManager.lastLocation {
                            pacer.recordControlLine(using: location)
                            dismiss()
                        }
                    } label: {
                        Label("今コントロールラインを通過", systemImage: "flag.checkered")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(locationManager.lastLocation == nil)

                    if locationManager.lastLocation == nil {
                        Label("GPSの位置情報を取得中です…", systemImage: "location.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("コントロールライン")
                }

                if let line = pacer.controlLine {
                    Section {
                        LabeledContent("緯度", value: String(format: "%.6f", line.latitude))
                        LabeledContent("経度", value: String(format: "%.6f", line.longitude))
                        LabeledContent("進行方向", value: String(format: "%.0f°", line.headingDegrees))
                        LabeledContent("基準ラップ") {
                            Text(pacer.hasReferenceLap ? "記録済み" : "未記録")
                                .foregroundStyle(pacer.hasReferenceLap ? .green : .secondary)
                        }

                        Button(role: .destructive) {
                            showingResetConfirmation = true
                        } label: {
                            Label("設定をリセット", systemImage: "trash")
                        }
                    } header: {
                        Text("現在の設定")
                    }
                }

                Section {
                    Stepper(value: $pacer.targetLapSeconds, in: 60...600, step: 1) {
                        LabeledContent("目標ラップタイム", value: targetTimeText)
                    }
                    Button("3'15\"00 にリセット（Challenge 180）") {
                        pacer.targetLapSeconds = 195
                    }
                    .font(.footnote)
                } header: {
                    Text("目標タイム")
                } footer: {
                    Text("速すぎるとペナルティ、遅いほど成績が悪くなるため、目標ぴったりで通過するのが理想です。")
                }

                Section {
                    Text("運転中の操作は危険です。同乗者が操作するか、必ず停車中またはピット内で設定してください。スマートフォンのGPSには数m〜十数mの誤差があり、このアプリの表示はあくまで目安です。走行はドライバー自身の判断と責任で行ってください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .confirmationDialog(
                "コントロールラインと記録をすべて消去しますか？",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("リセット", role: .destructive) {
                    pacer.resetControlLine()
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    private var targetTimeText: String {
        let m = Int(pacer.targetLapSeconds) / 60
        let s = Int(pacer.targetLapSeconds) % 60
        return String(format: "%d'%02d\"00", m, s)
    }
}
