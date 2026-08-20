import Foundation
import CoreLocation
import Observation

/// コントロールラインの通過検出と、目標ラップタイムに対するペース判定を行うエンジン。
///
/// 仕組み:
/// 1. コントロールラインを1度キャリブレーション（通過した瞬間の位置と進行方向を記録）する。
/// 2. 通過を検出するたびにラップを区切り、経過時間をリセットする。
/// 3. 走行中は常に「今の速度を維持したまま残り距離を走ると、目標タイムより早く着くか・遅く着くか」を計算し、
///    早く着く見込みなら減速、遅く着く見込みなら加速を指示する。過去の周回データに依存しないため、1周目から有効。
///
/// 精度についての注意: スマートフォンのGPSは通常1Hz程度の更新頻度・数m〜十数mの誤差があるため、
/// このアプリは「目安」であり、コンマ何秒の完全な精度を保証するものではない。
@Observable
final class LapPacer {
    // MARK: - 設定（永続化）

    var controlLine: ControlLine? {
        didSet { persistControlLine() }
    }

    var targetLapSeconds: Double = 195 {
        didSet { persistTargetLapSeconds() }
    }

    /// あらかじめ定義された走行ライン（コントロールラインから1周分の点列）。
    /// 設定されていれば、その経路に沿った距離を使って残り距離を計算する。
    /// 未設定の場合は、コントロールラインまでの直線距離にフォールバックする。
    private(set) var coursePath: CoursePath? {
        didSet { persistCoursePath() }
    }

    // MARK: - リアルタイム状態（UI表示用）

    private(set) var currentSpeedKmh: Double?
    private(set) var horizontalAccuracy: Double?
    private(set) var distanceToLineMeters: Double?
    private(set) var elapsedSinceCrossing: Double = 0
    private(set) var remainingToTarget: Double = 195
    private(set) var paceState: PaceState = .notCalibrated
    private(set) var laps: [LapRecord] = []

    // MARK: - 内部状態

    /// コースパス上での現在の進行距離（コースパス未設定時はnil）。次回投影の探索窓の中心にも使う。
    private var lastPathDistance: Double?
    private var lapStartDate: Date?
    private var lastCrossingDate: Date?
    private var previousLocation: CLLocation?
    private var previousAlong: Double?

    // MARK: - チューニング定数

    /// クロス判定を有効とみなす、ラインからの左右方向の許容オフセット（m）
    private static let lateralTolerance = 30.0
    /// クロス判定時、直前・直後のフィックスがライン付近（この距離未満）にある必要がある（m）
    private static let proximityRadius = 150.0
    /// 連続したクロス誤検出（GPSのジッターによる瞬間的な符号反転など）を防ぐための最小ラップ間隔（秒）。
    /// 短い周回でのテスト走行でも正しく毎周検出できるよう、実際のラップタイムより十分小さい値にしてある。
    private static let guardSeconds = 15.0
    /// ペース差がこの範囲内なら「オンペース」とみなす不感帯（秒）
    private static let deadband = 0.3
    /// この速度（m/s）未満では現在速度に基づく到達時刻の予測が不安定なため、ペース判定を保留する
    private static let minimumSpeedForPace = 1.0
    /// この精度（m）を超える位置情報フィックスは無視する
    private static let maxAcceptableAccuracy = 50.0

    // MARK: - UserDefaults キー

    private enum DefaultsKey {
        static let controlLine = "pace.controlLine"
        static let targetLapSeconds = "pace.targetLapSeconds"
        static let coursePath = "pace.coursePath"
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: DefaultsKey.controlLine),
           let decoded = try? JSONDecoder().decode(ControlLine.self, from: data) {
            controlLine = decoded
        }
        if defaults.object(forKey: DefaultsKey.targetLapSeconds) != nil {
            let stored = defaults.double(forKey: DefaultsKey.targetLapSeconds)
            if stored > 0 { targetLapSeconds = stored }
        }
        if let data = defaults.data(forKey: DefaultsKey.coursePath),
           let decoded = try? JSONDecoder().decode(CoursePath.self, from: data) {
            coursePath = decoded
        }
        remainingToTarget = targetLapSeconds
        paceState = controlLine == nil ? .notCalibrated : .waitingForData
    }

    // MARK: - キャリブレーション

    /// コントロールラインを通過した瞬間に呼ぶ。現在地と進行方向をラインとして記録し、ラップ計測を開始する。
    func recordControlLine(using location: CLLocation) {
        let heading = location.course >= 0 ? location.course : (previousLocation?.course ?? 0)
        applyNewControlLine(ControlLine(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            headingDegrees: heading
        ))
        startNewLap(at: location.timestamp)
        previousLocation = location
        previousAlong = 0
    }

    /// 地図等で調べた座標を手入力してコントロールラインとして設定する。
    /// 実際に通過して記録する方式より誤差が大きくなりうるため、可能であれば後で通過記録に置き換えるのが望ましい。
    /// この場合、現在地はライン上にあるとは限らないためラップ計測はまだ開始せず、次に実際にラインを通過した時点から始まる。
    func setControlLine(latitude: Double, longitude: Double, headingDegrees: Double) {
        applyNewControlLine(ControlLine(
            latitude: latitude,
            longitude: longitude,
            headingDegrees: headingDegrees
        ))
    }

    private func applyNewControlLine(_ line: ControlLine) {
        controlLine = line
        laps = []
        lapStartDate = nil
        lastCrossingDate = nil
        lastPathDistance = nil
        previousAlong = nil
        elapsedSinceCrossing = 0
        remainingToTarget = targetLapSeconds
        paceState = .waitingForData
    }

    /// 走行ライン（コースパス）を設定する。地図タップ、走って記録、またはCSV/GPXの読み込みで作った点列を渡す。
    func setCoursePath(_ path: CoursePath) {
        coursePath = path
        lastPathDistance = lapStartDate != nil ? 0 : nil
    }

    /// 走行ライン（コースパス）だけを消去する。コントロールラインはそのまま残る。
    func clearCoursePath() {
        coursePath = nil
        lastPathDistance = nil
    }

    /// コントロールラインと走行履歴をすべて消去する。走行ライン（コースパス）は残る。
    func resetControlLine() {
        controlLine = nil
        laps = []
        lapStartDate = nil
        lastCrossingDate = nil
        lastPathDistance = nil
        previousAlong = nil
        elapsedSinceCrossing = 0
        remainingToTarget = targetLapSeconds
        paceState = .notCalibrated
    }

    // MARK: - 位置情報の取り込み

    func ingest(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < Self.maxAcceptableAccuracy else {
            return
        }
        horizontalAccuracy = location.horizontalAccuracy
        updateSpeed(with: location)

        guard let line = controlLine else {
            previousLocation = location
            return
        }

        // 走行ライン（コースパス）が設定されていれば、それに沿った距離を使う方が
        // 直線距離より正確なので優先する。
        let pathProjection = (coursePath?.isUsable == true)
            ? coursePath?.project(location.coordinate, near: lastPathDistance)
            : nil

        if let pathProjection {
            lastPathDistance = pathProjection.distanceAlongPath
            distanceToLineMeters = max(0, (coursePath?.totalLength ?? 0) - pathProjection.distanceAlongPath)
        } else {
            distanceToLineMeters = location.distance(from: line.location)
        }

        let projection = line.project(location.coordinate)
        checkForCrossing(prevAlong: previousAlong, along: projection.along, lateral: projection.lateral, prevLocation: previousLocation, location: location)
        previousAlong = projection.along

        if let start = lapStartDate {
            elapsedSinceCrossing = max(0, location.timestamp.timeIntervalSince(start))
            remainingToTarget = targetLapSeconds - elapsedSinceCrossing
            updatePaceState()
        }

        previousLocation = location
    }

    // MARK: - 速度

    private func updateSpeed(with location: CLLocation) {
        if location.speed >= 0 {
            currentSpeedKmh = location.speed * 3.6
        } else if let prev = previousLocation {
            let dt = location.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0.1 {
                currentSpeedKmh = location.distance(from: prev) / dt * 3.6
            }
        }
    }

    // MARK: - ライン通過検出

    private func checkForCrossing(prevAlong: Double?, along: Double, lateral: Double, prevLocation: CLLocation?, location: CLLocation) {
        guard let prevAlong, prevAlong < 0, along >= 0, let prevLocation else { return }

        let lateralOK = abs(lateral) < Self.lateralTolerance
        let proximityOK = abs(prevAlong) < Self.proximityRadius && abs(along) < Self.proximityRadius
        let guardOK = lastCrossingDate.map { location.timestamp.timeIntervalSince($0) > Self.guardSeconds } ?? true

        guard lateralOK, proximityOK, guardOK else { return }

        let dt = location.timestamp.timeIntervalSince(prevLocation.timestamp)
        let fraction = dt > 0 ? prevAlong / (prevAlong - along) : 0
        let crossingTime = prevLocation.timestamp.addingTimeInterval(dt * fraction)
        handleCrossing(at: crossingTime)
    }

    private func handleCrossing(at date: Date) {
        if let start = lapStartDate {
            let duration = date.timeIntervalSince(start)
            laps.insert(LapRecord(duration: duration, date: date), at: 0)
            if laps.count > 20 { laps.removeLast() }
        }
        startNewLap(at: date)
    }

    private func startNewLap(at date: Date) {
        lapStartDate = date
        lastCrossingDate = date
        lastPathDistance = (coursePath?.isUsable == true) ? 0 : nil
        elapsedSinceCrossing = 0
        remainingToTarget = targetLapSeconds
        paceState = .waitingForData
    }

    // MARK: - ペース判定

    /// 「今の速度のまま残り距離を走ると、目標タイムより早く着くか・遅く着くか」を判定する。
    private func updatePaceState() {
        guard let distance = distanceToLineMeters, let speedKmh = currentSpeedKmh else {
            paceState = .waitingForData
            return
        }
        let speed = speedKmh / 3.6
        guard speed >= Self.minimumSpeedForPace else {
            paceState = .waitingForData
            return
        }

        let projectedTimeToLine = distance / speed
        let projectedTotalElapsed = elapsedSinceCrossing + projectedTimeToLine
        // delta > 0: このままだと目標より遅く着く(加速すべき) / delta < 0: 目標より早く着く(減速すべき)
        let delta = projectedTotalElapsed - targetLapSeconds

        if abs(delta) <= Self.deadband {
            paceState = .onPace
        } else if delta > 0 {
            paceState = .speedUp(seconds: delta)
        } else {
            paceState = .slowDown(seconds: -delta)
        }
    }

    // MARK: - 永続化

    private func persistControlLine() {
        let defaults = UserDefaults.standard
        if let line = controlLine, let data = try? JSONEncoder().encode(line) {
            defaults.set(data, forKey: DefaultsKey.controlLine)
        } else {
            defaults.removeObject(forKey: DefaultsKey.controlLine)
        }
    }

    private func persistTargetLapSeconds() {
        UserDefaults.standard.set(targetLapSeconds, forKey: DefaultsKey.targetLapSeconds)
    }

    private func persistCoursePath() {
        let defaults = UserDefaults.standard
        if let path = coursePath, let data = try? JSONEncoder().encode(path) {
            defaults.set(data, forKey: DefaultsKey.coursePath)
        } else {
            defaults.removeObject(forKey: DefaultsKey.coursePath)
        }
    }
}
