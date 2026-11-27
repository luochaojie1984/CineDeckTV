import Foundation

/// 从标准 `.nfo` 侧车文件解析出的高清影片元数据（兼容 MDCz / Emby / Jellyfin / Kodi 格式）。
public struct MovieMetadata: Codable, Hashable, Sendable {
    public var code: String?
    public var title: String
    public var originalTitle: String?
    public var plot: String?
    public var releaseDate: String?
    public var year: Int?
    public var runtimeMinutes: Int?
    public var rating: Double?
    public var studio: String?
    public var publisher: String?
    public var director: String?
    public var series: String?
    public var actors: [String]
    public var genres: [String]
    public var tags: [String]

    public init(
        code: String? = nil,
        title: String,
        originalTitle: String? = nil,
        plot: String? = nil,
        releaseDate: String? = nil,
        year: Int? = nil,
        runtimeMinutes: Int? = nil,
        rating: Double? = nil,
        studio: String? = nil,
        publisher: String? = nil,
        director: String? = nil,
        series: String? = nil,
        actors: [String] = [],
        genres: [String] = [],
        tags: [String] = []
    ) {
        self.code = code
        self.title = title
        self.originalTitle = originalTitle
        self.plot = plot
        self.releaseDate = releaseDate
        self.year = year
        self.runtimeMinutes = runtimeMinutes
        self.rating = rating
        self.studio = studio
        self.publisher = publisher
        self.director = director
        self.series = series
        self.actors = actors
        self.genres = genres
        self.tags = tags
    }
}
