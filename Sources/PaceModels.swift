import Foundation
import CoreLocation

/// コントロールライン（計測ライン）の位置と、通過時の進行方向。
/// 進行方向を基準に「ラインより手前 / 通過後」「ラインからの左右オフセット」を判定するために使う。
struct ControlLine: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    /// ライン通過時のコース方位（真北から時計回り、度）
    var headingDegrees: Double

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 指定した座標を、ラインの進行方向を基準にした座標系へ投影する。
    /// - along: 進行方向に沿った符号付き距離（m）。ラインより手前は負、通過後は正。
    /// - lateral: 進行方向に対して垂直な方向のオフセット（m）。ラインからの左右のズレ。
    ///
    /// 緯度経度から距離（m）への変換は、コース規模（数km程度）では十分な精度の
    /// 正距円筒近似（1度あたりの距離を定数とみなす）を用いている。
    func project(_ coordinate: CLLocationCoordinate2D) -> (along: Double, lateral: Double) {
        let latRad = latitude * .pi / 180
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = 111_320.0 * cos(latRad)

        let dx = (coordinate.longitude - longitude) * metersPerDegreeLongitude
        let dy = (coordinate.latitude - latitude) * metersPerDegreeLatitude

        let headingRad = headingDegrees * .pi / 180
        let along = dx * sin(headingRad) + dy * cos(headingRad)
        let lateral = dx * cos(headingRad) - dy * sin(headingRad)
        return (along, lateral)
    }
}

/// 完走した1周分の記録。
struct LapRecord: Identifiable, Codable {
    let id: UUID
    let duration: Double
    let date: Date

    init(duration: Double, date: Date = Date()) {
        self.id = UUID()
        self.duration = duration
        self.date = date
    }
}

/// 基準ラップ（お手本ペース）上の1点。
/// 「ライン通過からの走行距離」に対して「目標ラップタイムに換算した経過時間」を対応付ける。
struct ReferencePoint: Codable {
    let distance: Double
    let time: Double
}

/// 現在のペース判定結果。
enum PaceState: Equatable {
    /// コントロールラインが未設定
    case notCalibrated
    /// 基準ラップがまだ無い（キャリブレーション後、最初の1周を走行中）
    case noReference
    /// 目標ペース通り
    case onPace
    /// 目標より遅れている → 加速すべき（差は秒）
    case speedUp(seconds: Double)
    /// 目標より進みすぎている → 減速すべき（差は秒）
    case slowDown(seconds: Double)
}

/// 走行ライン（コースパス）上の1点。地図タップ、またはCSV/GPXの読み込みで得られる。
struct CoursePoint: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double
    /// ファイル等にタイムスタンプがあり、経路の最初の点からの経過秒が分かる場合のみ設定される。
    var elapsedSeconds: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// コントロールラインから1周分の走行ラインを表す点列。
/// points[0] がコントロールライン、以降を順にたどって1周し、最後の点が再びライン付近に戻る想定。
struct CoursePath: Codable, Equatable {
    var points: [CoursePoint]

    var isUsable: Bool { points.count >= 2 }

    /// 各点までの累積距離（points[0]を0とする、m）
    var cumulativeDistances: [Double] {
        guard points.count > 1 else { return points.map { _ in 0 } }
        var result = [0.0]
        var total = 0.0
        for i in 1..<points.count {
            total += points[i - 1].coordinate.distanceInMeters(to: points[i].coordinate)
            result.append(total)
        }
        return result
    }

    var totalLength: Double { cumulativeDistances.last ?? 0 }

    /// 現在地をこのコースパス上に投影し、開始点からの経路に沿った距離と、経路からの垂直方向のズレを返す。
    /// - previousDistance: 直前の投影結果（連続性を保つための探索窓の中心）。nilなら全区間から探索する。
    ///
    /// コースが自己交差に近い区間（ヘアピン、ピット入口など）を持つ場合、全区間から単純に最近傍を
    /// 探すと誤って別の区間に飛んでしまうことがあるため、直前の位置付近を優先的に探索し、
    /// 妥当な候補が無い場合のみ全区間探索にフォールバックする。
    func project(_ coordinate: CLLocationCoordinate2D, near previousDistance: Double?, searchWindow: Double = 120, fallbackThreshold: Double = 80) -> (distanceAlongPath: Double, lateralDistance: Double)? {
        guard points.count > 1 else { return nil }
        let distances = cumulativeDistances

        func bestMatch(restrictToWindow: Bool) -> (distance: Double, lateral: Double)? {
            var bestDistanceAlong = 0.0
            var bestLateral = Double.greatestFiniteMagnitude
            for i in 0..<(points.count - 1) {
                if restrictToWindow, let previousDistance {
                    let segStart = distances[i]
                    let withinWindow = segStart > previousDistance - searchWindow / 2 && segStart < previousDistance + searchWindow
                    guard withinWindow else { continue }
                }
                let (lateral, fraction) = Self.projectOntoSegment(coordinate, a: points[i].coordinate, b: points[i + 1].coordinate)
                if lateral < bestLateral {
                    bestLateral = lateral
                    let segmentLength = distances[i + 1] - distances[i]
                    bestDistanceAlong = distances[i] + fraction * segmentLength
                }
            }
            return bestLateral == .greatestFiniteMagnitude ? nil : (bestDistanceAlong, bestLateral)
        }

        if let windowed = bestMatch(restrictToWindow: true), windowed.lateral <= fallbackThreshold {
            return (windowed.distance, windowed.lateral)
        }
        guard let full = bestMatch(restrictToWindow: false) else { return nil }
        return (full.distance, full.lateral)
    }

    /// 点にインポート時の経過秒が付いている場合、それを目標ラップタイムに換算した基準ペースへ変換する。
    func referencePoints(scaledToTargetSeconds target: Double) -> [ReferencePoint]? {
        guard points.count > 1, let lastTime = points.last?.elapsedSeconds, lastTime > 0 else { return nil }
        let distances = cumulativeDistances
        var result: [ReferencePoint] = []
        for (index, point) in points.enumerated() {
            guard let time = point.elapsedSeconds else { continue }
            result.append(ReferencePoint(distance: distances[index], time: time * target / lastTime))
        }
        return result.count >= 2 ? result : nil
    }

    /// 点a→bの線分に対する、点の垂直距離(m)と、a側からの内分率(0〜1)を返す。
    /// メートル換算は線分開始点a付近を原点とした正距円筒近似（区間が数十〜数百m程度なら十分な精度）。
    private static func projectOntoSegment(_ point: CLLocationCoordinate2D, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> (lateral: Double, fraction: Double) {
        let latRad = a.latitude * .pi / 180
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = 111_320.0 * cos(latRad)

        func toXY(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - a.longitude) * metersPerDegreeLongitude, (c.latitude - a.latitude) * metersPerDegreeLatitude)
        }

        let ab = toXY(b)
        let ap = toXY(point)
        let abLengthSquared = ab.x * ab.x + ab.y * ab.y
        let fraction = abLengthSquared > 0 ? max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / abLengthSquared)) : 0
        let closestX = fraction * ab.x
        let closestY = fraction * ab.y
        let dx = ap.x - closestX
        let dy = ap.y - closestY
        return (sqrt(dx * dx + dy * dy), fraction)
    }
}

extension CLLocationCoordinate2D {
    func distanceInMeters(to other: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
