import Foundation
import CoreLocation
import Observation

/// コントロールラインの通過検出と、目標ラップタイムに対するペース判定を行うエンジン。
///
/// 仕組み:
/// 1. コントロールラインを1度キャリブレーション（通過した瞬間の位置と進行方向を記録）する。
/// 2. 通過を検出するたびにラップを区切り、そのラップの走行軌跡（走行距離 → 経過時間）を記録する。
/// 3. 完走した1周を「目標ラップタイムに換算」してスケール（例: 実際200秒で走った周を195/200倍）した
///    ものを次周の基準ペース（お手本）として使い、以降のラップでは
///    「今の走行距離に対して基準ペースでは何秒経過しているはずか」と実際の経過時間を比較して
///    加速・減速を判定する。
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
    /// 設定されていれば、その経路に沿った距離を使って残り距離・基準ペースを計算する。
    /// 未設定の場合は、直線距離や実走行のGPS軌跡を使う従来の方式にフォールバックする。
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
    private(set) var hasReferenceLap: Bool = false

    // MARK: - 内部状態

    private var referenceLap: [ReferencePoint]? {
        didSet {
            hasReferenceLap = referenceLap != nil
            persistReferenceLap()
        }
    }

    private var currentLapPoints: [ReferencePoint] = []
    private var odometerSinceCrossing: Double = 0
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
    /// 連続したクロス誤検出を防ぐための最小ラップ間隔（秒）
    private static let guardSeconds = 90.0
    /// ペース差がこの範囲内なら「オンペース」とみなす不感帯（秒）
    private static let deadband = 0.3
    /// 基準ラップとして採用する最小ポイント数
    private static let minimumReferencePoints = 15
    /// 基準ラップとして採用する妥当なラップ時間の範囲（秒）
    private static let plausibleLapRange = 60.0...600.0
    /// この精度（m）を超える位置情報フィックスは無視する
    private static let maxAcceptableAccuracy = 50.0

    // MARK: - UserDefaults キー

    private enum DefaultsKey {
        static let controlLine = "pace.controlLine"
        static let targetLapSeconds = "pace.targetLapSeconds"
        static let referenceLap = "pace.referenceLap"
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
        if let data = defaults.data(forKey: DefaultsKey.referenceLap),
           let decoded = try? JSONDecoder().decode([ReferencePoint].self, from: data) {
            referenceLap = decoded
        }
        if let data = defaults.data(forKey: DefaultsKey.coursePath),
           let decoded = try? JSONDecoder().decode(CoursePath.self, from: data) {
            coursePath = decoded
        }
        remainingToTarget = targetLapSeconds
        paceState = controlLine == nil ? .notCalibrated : .noReference
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
        referenceLap = nil
        laps = []
        lapStartDate = nil
        lastCrossingDate = nil
        odometerSinceCrossing = 0
        lastPathDistance = nil
        currentLapPoints = []
        previousAlong = nil
        elapsedSinceCrossing = 0
        remainingToTarget = targetLapSeconds
        paceState = .noReference
    }

    /// 走行ライン（コースパス）を設定する。地図タップ、またはCSV/GPXの読み込みで作った点列を渡す。
    /// 点にインポート時の経過秒が付いていれば、その軌跡をそのまま目標タイムに換算した基準ペースとして
    /// 即座に採用する（実走行1周を待たずにペース判定が有効になる）。
    func setCoursePath(_ path: CoursePath) {
        coursePath = path
        if let imported = path.referencePoints(scaledToTargetSeconds: targetLapSeconds) {
            referenceLap = imported
        }
        lastPathDistance = lapStartDate != nil ? 0 : nil
    }

    /// 走行ライン（コースパス）だけを消去する。コントロールラインや基準ペースはそのまま残る。
    func clearCoursePath() {
        coursePath = nil
        lastPathDistance = nil
    }

    /// コントロールラインと基準ラップ・履歴をすべて消去する。走行ライン（コースパス）は残る。
    func resetControlLine() {
        controlLine = nil
        referenceLap = nil
        laps = []
        lapStartDate = nil
        lastCrossingDate = nil
        odometerSinceCrossing = 0
        lastPathDistance = nil
        currentLapPoints = []
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
        // 直線距離や実測オドメーターより正確なので優先する。
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
            let elapsed = max(0, location.timestamp.timeIntervalSince(start))
            elapsedSinceCrossing = elapsed
            remainingToTarget = targetLapSeconds - elapsed

            let progressDistance: Double
            if let pathProjection {
                progressDistance = pathProjection.distanceAlongPath
                if currentLapPoints.last.map({ progressDistance - $0.distance > 0.5 }) ?? true {
                    currentLapPoints.append(ReferencePoint(distance: progressDistance, time: elapsed))
                }
            } else {
                if let prev = previousLocation {
                    let delta = location.distance(from: prev)
                    if delta > 1.0 {
                        odometerSinceCrossing += delta
                        currentLapPoints.append(ReferencePoint(distance: odometerSinceCrossing, time: elapsed))
                    }
                }
                progressDistance = odometerSinceCrossing
            }
            updatePaceState(usingDistance: progressDistance)
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

            if currentLapPoints.count >= Self.minimumReferencePoints, Self.plausibleLapRange.contains(duration) {
                let scale = targetLapSeconds / duration
                referenceLap = currentLapPoints.map { ReferencePoint(distance: $0.distance, time: $0.time * scale) }
            }
        }
        startNewLap(at: date)
    }

    private func startNewLap(at date: Date) {
        lapStartDate = date
        lastCrossingDate = date
        odometerSinceCrossing = 0
        lastPathDistance = (coursePath?.isUsable == true) ? 0 : nil
        currentLapPoints = []
        elapsedSinceCrossing = 0
        remainingToTarget = targetLapSeconds
        paceState = hasReferenceLap ? .onPace : .noReference
    }

    // MARK: - ペース判定

    private func updatePaceState(usingDistance distance: Double) {
        guard let reference = referenceLap, reference.count >= 2 else {
            paceState = .noReference
            return
        }
        let scheduled = scheduledTime(forDistance: distance, in: reference)
        // delta > 0: 基準ペースより遅れている(加速すべき) / delta < 0: 進みすぎている(減速すべき)
        let delta = elapsedSinceCrossing - scheduled

        if abs(delta) <= Self.deadband {
            paceState = .onPace
        } else if delta > 0 {
            paceState = .speedUp(seconds: delta)
        } else {
            paceState = .slowDown(seconds: -delta)
        }
    }

    private func scheduledTime(forDistance distance: Double, in reference: [ReferencePoint]) -> Double {
        guard let first = reference.first, let last = reference.last else { return targetLapSeconds }
        if distance <= first.distance { return first.time }
        if distance >= last.distance { return last.time }

        var lower = first
        for point in reference {
            if point.distance >= distance {
                guard point.distance > lower.distance else { return point.time }
                let t = (distance - lower.distance) / (point.distance - lower.distance)
                return lower.time + t * (point.time - lower.time)
            }
            lower = point
        }
        return last.time
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

    private func persistReferenceLap() {
        let defaults = UserDefaults.standard
        if let reference = referenceLap, let data = try? JSONEncoder().encode(reference) {
            defaults.set(data, forKey: DefaultsKey.referenceLap)
        } else {
            defaults.removeObject(forKey: DefaultsKey.referenceLap)
        }
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
