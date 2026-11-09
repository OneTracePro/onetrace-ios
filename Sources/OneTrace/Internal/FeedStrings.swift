import Foundation

/// Labels of the ready-made feed screen in the platform's languages, the same wording as the website feed widget
/// (`feed-i18n.js` of the tracker). The device language picks them; English for other languages.
struct FeedStrings: Equatable {
    let title: String
    let empty: String
    let dismiss: String
    let pinned: String

    static let all: [String: FeedStrings] = [
        "en": FeedStrings(title: "Updates", empty: "Offers and news from the shop will appear here.", dismiss: "Remove", pinned: "Pinned"),
        "ru": FeedStrings(title: "Новости", empty: "Здесь появятся предложения и новости магазина.", dismiss: "Убрать", pinned: "Закреплено"),
        "de": FeedStrings(title: "Neuigkeiten", empty: "Hier erscheinen Angebote und Neuigkeiten des Shops.", dismiss: "Entfernen", pinned: "Angeheftet"),
        "uz": FeedStrings(title: "Yangiliklar", empty: "Bu yerda doʻkonning takliflari va yangiliklari paydo boʻladi.", dismiss: "Olib tashlash", pinned: "Mahkamlangan"),
        "tr": FeedStrings(title: "Haberler", empty: "Mağazanın teklifleri ve haberleri burada görünecek.", dismiss: "Kaldır", pinned: "Sabitlendi"),
        "es": FeedStrings(title: "Novedades", empty: "Aquí aparecerán las ofertas y novedades de la tienda.", dismiss: "Quitar", pinned: "Fijado"),
        "fr": FeedStrings(title: "Actualités", empty: "Les offres et actualités de la boutique apparaîtront ici.", dismiss: "Retirer", pinned: "Épinglé"),
        "it": FeedStrings(title: "Novità", empty: "Qui compariranno le offerte e le novità del negozio.", dismiss: "Rimuovi", pinned: "Fissato"),
        "pt": FeedStrings(title: "Novidades", empty: "As ofertas e novidades da loja aparecerão aqui.", dismiss: "Remover", pinned: "Fixado"),
        "zh": FeedStrings(title: "最新消息", empty: "商店的优惠和新闻将显示在这里。", dismiss: "移除", pinned: "已置顶"),
    ]

    /// `language` such as `de`, `pt-BR` or `zh-Hans-CN`; nil — the first preferred language of the app.
    static func forLanguage(_ language: String?) -> FeedStrings {
        let tag = (language ?? Locale.preferredLanguages.first ?? "en").lowercased()
        let code = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        return all[code] ?? all["en"]!
    }
}
