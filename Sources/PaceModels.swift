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
