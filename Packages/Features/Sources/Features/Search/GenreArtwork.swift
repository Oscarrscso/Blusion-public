import Foundation

/// Landscape stills for the genres shown on Search's empty page.
/// The URLs are deliberately independent of the catalog source; if an addon uses an unrecognised genre,
/// Search keeps the existing coloured tile instead.
enum GenreArtwork {
    private static let urls: [String: String] = [
        "action": "https://cdni.fancaps.net/file/fancaps-movieimages/1417945.jpg", // Mad Max: Fury Road
        "adventure": "https://media.gq-magazin.de/photos/5e579fd92662b70008f72af8/16%3A9/w_2560%2Cc_limit/Entertainment-Indiana-Jones-Regie.jpg", // Indiana Jones
        "animation": "https://pbs.twimg.com/amplify_video_thumb/1664592670608572416/img/0jqVcbkQJhp5s3Wm.jpg", // Across the Spider-Verse
        "comedy": "https://uploads.lebonbon.fr/source/2023/january/2039880/the-grand-budapest-hotel-still_1_2000.jpg", // The Grand Budapest Hotel
        "crime": "https://www.mauxa.com/storage/newsgallery/2022/01/the-godfather---il-padrino--il-50-anniversario-del-film--trama-cast-quando-esce-notizie-when-is-the-coming-out-plot-streaming-now-google-play-amazon-prime-video3.jpeg", // The Godfather
        "documentary": "https://cf-images.us-east-1.prod.boltdns.net/v1/static/6415983392001/19fc9120-09f5-4756-a8fb-1811b2b21fd2/df2c2e7e-6460-4207-a8ff-f86f9c7400f6/1280x720/match/image.jpg", // BBC snow leopard
        "drama": "https://media.gq-magazine.co.uk/photos/5d13948eb6fee9757ec9e6e4/16%3A9/w_2560%2Cc_limit/image.jpg", // Whiplash
        "family": "https://www.intofilm.org/intofilm-production/scaledcropped/3000x1688https%3A/www.intofilm.org/intofilm-production/487/paddington-header.jpg/paddington-header.jpg", // Paddington
        "fantasy": "https://images2.minutemediacdn.com/image/upload/c_crop%2Cw_1409%2Ch_792%2Cx_0%2Cy_0/images/ImageExchange/mmsport/385/01kfp3zhhvge4rbkef4z", // Lord of the Rings
        "history": "https://cdn.mos.cms.futurecdn.net/YzwmhXLXp4YpcpkGajUCuf.jpg", // Oppenheimer
        "horror": "https://images.squarespace-cdn.com/content/v1/61e8a17cae68793e9fa20bb5/ded51942-42a0-4464-afbe-a1627d03d4d5/the-shining-1980-219-8828.jpg", // The Shining
        "music": "https://cdn.mos.cms.futurecdn.net/cqJrwRj2R8yUVath53hTMR.jpg", // La La Land
        "mystery": "https://image.tmdb.org/t/p/w1920_and_h800_multi_faces/4HWAQu28e2yaWrtupFPGFkdNU7V.jpg", // Knives Out
        "romance": "https://images.lincolncenter.org/image/upload/v1715714789/hjdxrfpwdvl2lwnhejjs.jpg", // Before Sunrise
        "scifi": "https://image.tmdb.org/t/p/w780/m7ynwXIvSnhxQPR6pOICrC0L2sO.jpg", // Blade Runner 2049
        "thriller": "https://media.filmz.ru/photos/big/filmz.ru_b_144273.jpg", // Se7en
        "war": "https://images.squarespace-cdn.com/content/v1/63b5eefe58d11159090359cb/1752528898549-E6H2RT333K5NXV64G4KA/1917-019.jpg?format=2500w", // 1917
        "western": "https://a.ltrbxd.com/resized/alternative-backdrop/5/2/5/1/6/tmdb/eRKMY50e8f6PVOBXlUy71fQy1kd-1200-1200-675-675-crop-000000.jpg?v=ba0bdfb6fa", // Django Unchained
        "sport": "https://nofilmschool.com/media-library/sylvester-stallone-as-rocky-finishing-his-run-at-the-philadelphia-museum-of-art.jpg?coordinates=0%2C0%2C0%2C0&height=700&id=61489164&quality=90&width=1245", // Rocky
        "reality": "https://realitytvworld.b-cdn.net/img/e-26763-700-400.jpg", // Survivor
        "kids": "https://images.moviesanywhere.com/420e80f6ed19264d2a09c27be02bb7a9/dcb001ee-19b4-4e11-84d8-8a63c03d7b64.jpg?r=16x9&w=2560", // Toy Story
        "anime": "https://uc.udn.com.tw/photo/2025/08/21/105/33099551.jpg", // Spirited Away
    ]

    static func imageURL(for genre: String) -> URL? {
        let normalised = String(genre.lowercased().filter(\.isLetter))
        let key: String
        switch normalised {
        case "sciencefiction", "sciencefictionandfantasy", "scifiandfantasy": key = "scifi"
        case "children", "childrens", "kidsandfamily": key = "kids"
        case "realitytv", "realitytelevision": key = "reality"
        case "sports": key = "sport"
        case "historical": key = "history"
        case "actionandadventure": key = "action"
        case "musical", "musicals": key = "music"
        default: key = normalised
        }
        return urls[key].flatMap(URL.init(string:))
    }
}
