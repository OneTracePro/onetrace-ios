import Foundation

/// The message feed of the current visitor: `GET /feed` by the anonymous id, the unread count, and the shown, clicked
/// and dismissed reports. The `…Now` methods run on the SDK queue; listeners get their calls through `deliver` (the main
/// thread in the app).
///
/// Reports are sent once, like in-app reports. A show or a dismiss the platform has not confirmed (no network) stays
/// in effect for this session: a refresh does not bring the card back as unread or back into the list.
final class Feed {
    private let transport: Transport
    private let anonymousId: () -> String
    private let log: (String) -> Void
    let deliver: (@escaping () -> Void) -> Void

    private var cards: [OneTraceFeedCard] = []
    private var shown: Set<String> = []
    private var dismissed: Set<String> = []
    /// The app uses the feed: it is refreshed when the app opens and after a sign-out.
    private var used = false
    private var loaded = false

    private var unreadListeners: [UUID: (Int) -> Void] = [:]
    private var cardListeners: [UUID: ([OneTraceFeedCard]) -> Void] = [:]
    private var publishedUnread = 0

    /// What the public getters read without waiting for the SDK queue, which may be busy with the network.
    private let lock = NSLock()
    private var snapshot: (cards: [OneTraceFeedCard], unread: Int) = ([], 0)

    init(transport: Transport, anonymousId: @escaping () -> String, log: @escaping (String) -> Void, deliver: @escaping (@escaping () -> Void) -> Void) {
        self.transport = transport
        self.anonymousId = anonymousId
        self.log = log
        self.deliver = deliver
    }

    var currentCards: [OneTraceFeedCard] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.cards
    }

    var currentUnread: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.unread
    }

    /// Loads the feed; on a network error the previous cards stay.
    @discardableResult
    func fetchNow() -> [OneTraceFeedCard] {
        used = true
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "anonymousId", value: anonymousId())]
        let result = transport.get("/feed?" + (query.percentEncodedQuery ?? ""))

        guard result.successful,
              let json = (try? JSONSerialization.jsonObject(with: Data(result.body.utf8))) as? [String: Any],
              let data = json["data"] as? [[String: Any]] else {
            log("Feed: HTTP \(result.status)")
            return cards
        }

        loaded = true
        cards = data.compactMap(OneTraceFeedCard.init(json:)).filter { !dismissed.contains($0.token) }.map { card in
            var card = card
            // Shown in this session, maybe not confirmed yet.
            if shown.contains(card.token) { card.read = true }
            return card
        }
        log("Feed: \(cards.count) cards")
        publish()

        return cards
    }

    /// The app opened again.
    func refreshIfUsedNow() {
        if used { fetchNow() }
    }

    /// Another visitor (sign-out): their own feed.
    func resetNow() {
        cards = []
        loaded = false
        publish()
        if used { fetchNow() }
    }

    /// The card became visible: reported once per session.
    func shownNow(_ token: String) {
        guard !shown.contains(token) else { return }
        shown.insert(token)
        if let index = cards.firstIndex(where: { $0.token == token }), cards[index].read { return }
        markRead(token)
        report(token, "shown", nil)
    }

    func clickedNow(_ token: String, _ url: String?) {
        markRead(token)
        report(token, "clicked", url)
    }

    func dismissedNow(_ token: String) {
        dismissed.insert(token)
        cards.removeAll { $0.token == token }
        publish()
        report(token, "dismissed", nil)
    }

    func observeUnread(_ listener: @escaping (Int) -> Void) -> UUID {
        let id = UUID()
        unreadListeners[id] = listener
        let unread = unreadCount
        deliver { listener(unread) }
        if !loaded { fetchNow() }
        return id
    }

    func observeCards(_ listener: @escaping ([OneTraceFeedCard]) -> Void) -> UUID {
        let id = UUID()
        cardListeners[id] = listener
        let current = cards
        deliver { listener(current) }
        return id
    }

    func removeListener(_ id: UUID) {
        unreadListeners[id] = nil
        cardListeners[id] = nil
    }

    private var unreadCount: Int { cards.filter { !$0.read }.count }

    private func markRead(_ token: String) {
        guard let index = cards.firstIndex(where: { $0.token == token }), !cards[index].read else { return }
        cards[index].read = true
        publish()
    }

    private func publish() {
        let current = cards
        let unread = unreadCount
        lock.lock()
        snapshot = (current, unread)
        lock.unlock()

        let cardListeners = Array(self.cardListeners.values)
        deliver { cardListeners.forEach { $0(current) } }

        guard unread != publishedUnread else { return }
        publishedUnread = unread
        let unreadListeners = Array(self.unreadListeners.values)
        deliver { unreadListeners.forEach { $0(unread) } }
    }

    private func report(_ token: String, _ event: String, _ url: String?) {
        var body: [String: Any] = ["token": token, "event": event]
        if let url = url { body["url"] = url }
        let result = transport.post("/feed/events", body)
        log("Feed \(event) reported: HTTP \(result.status)")
    }
}
