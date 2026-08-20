import SwiftUI
import CoreLocation

struct CalibrationView: View {
    @Bindable var pacer: LapPacer
    var locationManager: LocationManager

    @Environment(\.dismiss) private var dismiss
    @State private var showingResetConfirmation = false
    @State private var showingCoursePathEditor = false
    @State private var showingCoursePathRecorder = false
    @State private var showingCoursePathResetConfirmation = false
    @State private var latitudeText: String = ""
    @State private var longitudeText: String = ""
    @State private var headingText: String = ""
    @State private var targetMinutes = 3
    @State private var targetSeconds = 15

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
                    Text("コントロールライン（走行中に通過して設定）")
                }

                Section {
                    Text("Google Mapなどでラインの位置を長押しすると表示される座標をコピーして貼り付けてください。進行方向は、地図上でラインを通過する向きを、真北を0°として時計回りの角度（0〜360°）でおおよそ入力してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("緯度（例: 35.371700）", text: $latitudeText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("経度（例: 138.927000）", text: $longitudeText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("進行方向（0〜360°、真北=0°）", text: $headingText)
                        .keyboardType(.numbersAndPunctuation)

                    Button("この座標をコントロールラインに設定") {
                        guard let latitude = Double(latitudeText),
                              let longitude = Double(longitudeText),
                              let heading = Double(headingText) else { return }
                        pacer.setControlLine(latitude: latitude, longitude: longitude, headingDegrees: heading)
                    }
                    .disabled(!manualCoordinatesAreValid)
                } header: {
                    Text("座標を手入力して設定")
                } footer: {
                    Text("実際に通過して設定する方法より誤差が大きくなる場合があります。可能であれば、走行中に実際に通過して設定し直すことをおすすめします。")
                }

                if let line = pacer.controlLine {
                    Section {
                        LabeledContent("緯度", value: String(format: "%.6f", line.latitude))
                        LabeledContent("経度", value: String(format: "%.6f", line.longitude))
                        LabeledContent("進行方向", value: String(format: "%.0f°", line.headingDegrees))

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
                    Button {
                        showingCoursePathRecorder = true
                    } label: {
                        Label("走行ラインを走って記録", systemImage: "record.circle")
                    }
                    Button {
                        showingCoursePathEditor = true
                    } label: {
                        Label("走行ラインを編集", systemImage: "map")
                    }

                    if let path = pacer.coursePath {
                        LabeledContent("点の数", value: "\(path.points.count)")
                        LabeledContent("コース長", value: String(format: "%.0f m", path.totalLength))
                        LabeledContent("タイム情報") {
                            Text(path.points.contains { $0.elapsedSeconds != nil } ? "あり" : "なし")
                                .foregroundStyle(.secondary)
                        }

                        Button(role: .destructive) {
                            showingCoursePathResetConfirmation = true
                        } label: {
                            Label("走行ラインを削除", systemImage: "trash")
                        }
                    } else {
                        Text("未設定（設定すると、直線距離ではなく実際の走行ラインに沿った残り距離・時間を計算します）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("走行ライン（コースパス）")
                } footer: {
                    Text("実際に1周走って記録するか、地図をタップして点を置くか、GPSデータロガー等のGPX/CSVファイルを読み込んで、コントロールラインから1周分の走行ラインを設定できます。設定すると、コントロールラインまでの残り距離が直線距離ではなくこの経路に沿った距離になり、ペース判定もより正確になります。設定は任意で、無くても動作します。")
                }

                Section {
                    HStack {
                        Picker("分", selection: $targetMinutes) {
                            ForEach(0...10, id: \.self) { m in
                                Text("\(m)分").tag(m)
                            }
                        }
                        .pickerStyle(.wheel)

                        Picker("秒", selection: $targetSeconds) {
                            ForEach(0..<60, id: \.self) { s in
                                Text(String(format: "%02d秒", s)).tag(s)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                    .frame(height: 130)
                    .onChange(of: targetMinutes) { updateTargetLapSecondsFromPickers() }
                    .onChange(of: targetSeconds) { updateTargetLapSecondsFromPickers() }

                    Button("3'15\"00 にリセット（Challenge 180）") {
                        targetMinutes = 3
                        targetSeconds = 15
                        updateTargetLapSecondsFromPickers()
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
            .confirmationDialog(
                "走行ラインを削除しますか？",
                isPresented: $showingCoursePathResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    pacer.clearCoursePath()
                }
                Button("キャンセル", role: .cancel) {}
            }
            .sheet(isPresented: $showingCoursePathEditor) {
                CoursePathEditorView(pacer: pacer, locationManager: locationManager)
            }
            .sheet(isPresented: $showingCoursePathRecorder) {
                CoursePathRecorderView(pacer: pacer, locationManager: locationManager)
            }
            .onAppear {
                if let line = pacer.controlLine, latitudeText.isEmpty {
                    latitudeText = String(format: "%.6f", line.latitude)
                    longitudeText = String(format: "%.6f", line.longitude)
                    headingText = String(format: "%.0f", line.headingDegrees)
                }
                let total = Int(pacer.targetLapSeconds)
                targetMinutes = total / 60
                targetSeconds = total % 60
            }
        }
    }

    private var manualCoordinatesAreValid: Bool {
        guard let latitude = Double(latitudeText), (-90...90).contains(latitude),
              let longitude = Double(longitudeText), (-180...180).contains(longitude),
              let heading = Double(headingText), (0...360).contains(heading) else {
            return false
        }
        return true
    }

    private func updateTargetLapSecondsFromPickers() {
        pacer.targetLapSeconds = Double(targetMinutes * 60 + targetSeconds)
    }
}
