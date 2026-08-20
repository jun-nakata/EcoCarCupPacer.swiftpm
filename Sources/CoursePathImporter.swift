import Foundation

/// データロガー等から書き出したGPX/CSVを走行ラインの点列に変換する。
enum CoursePathImporter {
    /// ファイルの内容から形式を判定して読み込む。
    static func parseFile(data: Data, filename: String) -> [CoursePoint] {
        if filename.lowercased().hasSuffix(".gpx") {
            return GPXParser.parse(data: data)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.contains("<gpx") || text.contains("<trkpt") {
            return GPXParser.parse(data: data)
        }
        return parse(text: text)
    }

    /// 「緯度,経度」または「緯度,経度,経過秒」を1行ずつ並べたテキストを読み込む。
    /// カンマ・タブどちらの区切りにも対応し、数値として解釈できない行は無視する。
    static func parse(text: String) -> [CoursePoint] {
        var points: [CoursePoint] = []
        let separators = CharacterSet(charactersIn: ",\t")
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, let latitude = Double(fields[0]), let longitude = Double(fields[1]) else { continue }
            let elapsedSeconds = fields.count >= 3 ? Double(fields[2]) : nil
            points.append(CoursePoint(latitude: latitude, longitude: longitude, elapsedSeconds: elapsedSeconds))
        }
        return points
    }
}

/// GPXファイル内の<trkpt>/<wpt>要素から座標と（あれば）タイムスタンプを読み取る。
private final class GPXParser: NSObject, XMLParserDelegate {
    private var points: [CoursePoint] = []
    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private var currentTimeText = ""
    private var isInTimeElement = false
    private var firstTimestamp: Date?

    static func parse(data: Data) -> [CoursePoint] {
        let delegate = GPXParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.parse()
        return delegate.points
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "trkpt", "wpt":
            currentLatitude = attributeDict["lat"].flatMap(Double.init)
            currentLongitude = attributeDict["lon"].flatMap(Double.init)
            currentTimeText = ""
        case "time":
            isInTimeElement = true
            currentTimeText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTimeElement {
            currentTimeText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "time":
            isInTimeElement = false
        case "trkpt", "wpt":
            guard let latitude = currentLatitude, let longitude = currentLongitude else { return }
            var elapsedSeconds: Double?
            if let timestamp = Self.parseDate(currentTimeText) {
                if firstTimestamp == nil { firstTimestamp = timestamp }
                if let first = firstTimestamp {
                    elapsedSeconds = timestamp.timeIntervalSince(first)
                }
            }
            points.append(CoursePoint(latitude: latitude, longitude: longitude, elapsedSeconds: elapsedSeconds))
            currentLatitude = nil
            currentLongitude = nil
        default:
            break
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        return withoutFraction.date(from: trimmed)
    }
}
