import SwiftUI
import MapKit
import UniformTypeIdentifiers

/// 走行ライン（コースパス）を編集する画面。
/// 地図をタップして点を置いていく方法と、GPX/CSVファイルやテキストの貼り付けから読み込む方法の両方に対応する。
struct CoursePathEditorView: View {
    @Bindable var pacer: LapPacer
    var locationManager: LocationManager

    @Environment(\.dismiss) private var dismiss

    @State private var draftPoints: [CoursePoint] = []
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showingImporter = false
    @State private var showingPasteSheet = false
    @State private var pasteText = ""
    @State private var importErrorMessage: String?
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        if draftPoints.count > 1 {
                            MapPolyline(coordinates: draftPoints.map(\.coordinate))
                                .stroke(.blue, lineWidth: 3)
                        }
                        ForEach(Array(draftPoints.enumerated()), id: \.offset) { index, point in
                            Annotation("", coordinate: point.coordinate) {
                                Circle()
                                    .fill(index == 0 ? Color.red : Color.blue)
                                    .frame(width: index == 0 ? 14 : 8, height: index == 0 ? 14 : 8)
                            }
                        }
                        UserAnnotation()
                    }
                    .onTapGesture { screenPoint in
                        guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                        draftPoints.append(CoursePoint(latitude: coordinate.latitude, longitude: coordinate.longitude, elapsedSeconds: nil))
                    }
                }
                .frame(minHeight: 280)

                Form {
                    Section {
                        LabeledContent("点の数", value: "\(draftPoints.count)")
                        LabeledContent("推定コース長", value: lengthText)

                        Button("最後の点を取り消す") {
                            _ = draftPoints.popLast()
                        }
                        .disabled(draftPoints.isEmpty)

                        Button("すべて削除", role: .destructive) {
                            showingClearConfirmation = true
                        }
                        .disabled(draftPoints.isEmpty)
                    } header: {
                        Text("地図をタップして設定")
                    } footer: {
                        Text("赤い点がコントロールライン(1点目)です。そこから走行順に、コーナーの頂点や道なりの変化点を中心にタップして1周分の点を置き、最後はコントロールライン付近に戻してください。")
                    }

                    Section {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("ファイルから読み込む（GPX/CSV）", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            pasteText = ""
                            showingPasteSheet = true
                        } label: {
                            Label("テキストを貼り付けて読み込む", systemImage: "doc.on.clipboard")
                        }
                        if let importErrorMessage {
                            Text(importErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("データロガー等から読み込む")
                    } footer: {
                        Text("1行に「緯度,経度」または「緯度,経度,経過秒」（コントロールライン通過からの経過秒）を並べたCSV、またはGPXファイルに対応しています。経過秒つきで読み込むと、その軌跡がそのまま目標タイムに換算した基準ペースになります。読み込むと地図上の点はすべて置き換わります。")
                    }
                }
            }
            .navigationTitle("走行ライン（コースパス）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        pacer.setCoursePath(CoursePath(points: draftPoints))
                        dismiss()
                    }
                    .disabled(draftPoints.count < 2)
                }
            }
            .onAppear {
                draftPoints = pacer.coursePath?.points ?? []
                if let line = pacer.controlLine {
                    cameraPosition = .region(MKCoordinateRegion(center: line.coordinate, latitudinalMeters: 900, longitudinalMeters: 900))
                } else if let location = locationManager.lastLocation {
                    cameraPosition = .region(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 900, longitudinalMeters: 900))
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: importContentTypes) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showingPasteSheet) {
                pasteSheet
            }
            .confirmationDialog(
                "すべての点を削除しますか？",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) { draftPoints = [] }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("1行に「緯度,経度」または「緯度,経度,経過秒」を並べて貼り付けてください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                TextEditor(text: $pasteText)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal)
            }
            .padding(.top, 8)
            .navigationTitle("テキストから読み込み")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { showingPasteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("読み込む") {
                        applyImportedPoints(CoursePathImporter.parse(text: pasteText))
                        showingPasteSheet = false
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var importContentTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText, .xml, .item]
        if let gpx = UTType(filenameExtension: "gpx") { types.insert(gpx, at: 0) }
        return types
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                importErrorMessage = "ファイルを読み込めませんでした。"
                return
            }
            applyImportedPoints(CoursePathImporter.parseFile(data: data, filename: url.lastPathComponent))
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }

    private func applyImportedPoints(_ parsed: [CoursePoint]) {
        guard parsed.count >= 2 else {
            importErrorMessage = "座標を読み取れませんでした。フォーマットを確認してください。"
            return
        }
        importErrorMessage = nil
        draftPoints = parsed
        if let first = parsed.first {
            cameraPosition = .region(MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 900, longitudinalMeters: 900))
        }
    }

    private var lengthText: String {
        guard draftPoints.count > 1 else { return "--" }
        return String(format: "%.0f m", CoursePath(points: draftPoints).totalLength)
    }
}
