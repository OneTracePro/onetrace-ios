#if canImport(UIKit) && os(iOS)
import UIKit

/// The ready-made message feed screen: the cards in their layouts, pinned ones first, a remove button on each, pull to
/// refresh and an empty state. A card at least half visible on the open screen is reported as shown; a tap on its
/// button (or on a card without a button) reports the click and opens the link. Labels follow the device language,
/// colors the system light or dark appearance and the app tint.
///
/// ```swift
/// navigationController?.pushViewController(OneTraceFeedViewController(), animated: true)
/// // or modally with a Close button:
/// OneTrace.presentFeed()
/// ```
public final class OneTraceFeedViewController: UIViewController {
    private let strings: FeedStrings
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refresh = UIRefreshControl()
    private let empty = UILabel()
    private var cards: [OneTraceFeedCard] = []
    private var loaded = false
    private var appeared = false
    private var reported: Set<String> = []
    private var observation: OneTraceObservation?
    private var activeObserver: NSObjectProtocol?

    /// Shows a Close button: set by `OneTrace.presentFeed`.
    var closable = false

    /// - Parameter language: the labels language (`de`, `pt-BR`…); nil — the device language. English for languages
    ///   OneTrace does not have.
    public init(language: String? = nil) {
        strings = FeedStrings.forLanguage(language)
        super.init(nibName: nil, bundle: nil)
        title = strings.title
    }

    public required init?(coder: NSCoder) {
        strings = FeedStrings.forLanguage(nil)
        super.init(coder: coder)
        title = strings.title
    }

    deinit {
        observation?.cancel()
        if let observer = activeObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FeedCardCell.self, forCellReuseIdentifier: FeedCardCell.reuseIdentifier)
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        tableView.refreshControl = refresh

        empty.text = strings.empty
        empty.textAlignment = .center
        empty.numberOfLines = 0
        empty.textColor = .secondaryLabel
        empty.font = .preferredFont(forTextStyle: .subheadline)
        empty.adjustsFontForContentSizeCategory = true
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tableView)
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            empty.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            empty.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])

        if closable {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        }

        observation = OneTrace.observeFeed { [weak self] in self?.show($0) }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reportVisible()
        }
        reload()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        reportVisible()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appeared = false
    }

    @objc private func reload() {
        OneTrace.fetchFeed { [weak self] cards in
            guard let self = self else { return }
            self.loaded = true
            self.refresh.endRefreshing()
            self.show(cards)
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    /// New cards from a load or a report: removed cards fade out, read ones lose the unread border.
    private func show(_ next: [OneTraceFeedCard]) {
        let before = cards.map(\.token)
        let after = next.map(\.token)
        cards = next

        if before == after {
            for case let cell as FeedCardCell in tableView.visibleCells {
                if let indexPath = tableView.indexPath(for: cell) { cell.setRead(cards[indexPath.row].read) }
            }
        } else if !after.isEmpty, after.count < before.count, before.filter({ Set(after).contains($0) }) == after {
            let removed = before.indices.filter { !after.contains(before[$0]) }.map { IndexPath(row: $0, section: 0) }
            tableView.deleteRows(at: removed, with: .fade)
        } else {
            tableView.reloadData()
        }

        empty.isHidden = !(loaded && cards.isEmpty)
        tableView.layoutIfNeeded()
        reportVisible()
    }

    /// Reports the cards at least half visible while the feed is on screen and the app is active.
    private func reportVisible() {
        guard isViewLoaded, appeared, view.window != nil, UIApplication.shared.applicationState == .active else { return }
        let visible = tableView.bounds.inset(by: tableView.adjustedContentInset)

        for indexPath in tableView.indexPathsForVisibleRows ?? [] where indexPath.row < cards.count {
            let card = cards[indexPath.row]
            guard !card.read, !reported.contains(card.token) else { continue }
            let frame = tableView.rectForRow(at: indexPath).insetBy(dx: 0, dy: FeedCardCell.verticalMargin)
            if frame.height > 0, frame.intersection(visible).height * 2 >= frame.height {
                reported.insert(card.token)
                OneTrace.feedCardShown(card)
            }
        }
    }
}

extension OneTraceFeedViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        cards.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FeedCardCell.reuseIdentifier, for: indexPath)
        if let cell = cell as? FeedCardCell {
            let card = cards[indexPath.row]
            cell.configure(card, strings: strings, open: { OneTrace.feedCardClicked(card) }, dismiss: { OneTrace.feedCardDismissed(card) })
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard indexPath.row < cards.count, cards[indexPath.row].opensOnTap else { return }
        OneTrace.feedCardClicked(cards[indexPath.row])
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportVisible()
    }
}

extension OneTrace {
    /// Shows the feed screen with a Close button over `presenter`, or over the top screen of the key window. Main thread.
    ///
    /// - Parameter language: the labels language; nil — the device language.
    @MainActor
    public static func presentFeed(from presenter: UIViewController? = nil, language: String? = nil) {
        let feed = OneTraceFeedViewController(language: language)
        feed.closable = true
        guard let host = presenter ?? topViewController() else { return }
        host.present(UINavigationController(rootViewController: feed), animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// One card: the layout is built anew for each card, the image comes from `FeedImages`.
final class FeedCardCell: UITableViewCell {
    static let reuseIdentifier = "OneTraceFeedCard"
    static let verticalMargin: CGFloat = 6
    private static let imageHeight: CGFloat = 160

    private let cardView = UIView()
    private var imageURL: URL?
    private var read = true
    private weak var button: UIButton?
    private weak var pinned: UILabel?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 12
        cardView.layer.borderWidth = 1
        cardView.clipsToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        let bottom = cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalMargin)
        bottom.priority = .defaultHigh + 249
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalMargin),
            bottom,
            cardView.leadingAnchor.constraint(equalTo: contentView.readableContentGuide.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: contentView.readableContentGuide.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ card: OneTraceFeedCard, strings: FeedStrings, open: @escaping () -> Void, dismiss: @escaping () -> Void) {
        cardView.subviews.forEach { $0.removeFromSuperview() }
        imageURL = card.imageURL
        accessibilityTraits = card.opensOnTap ? .link : []

        let image = card.imageURL.map(makeImageView)
        var constraints: [NSLayoutConstraint] = []

        switch card.layout {
        case .classic:
            let text = textStack(card, strings, open)
            let views: [UIView?] = [image, text]
            let row = UIStackView(arrangedSubviews: views.compactMap { $0 })
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .top
            row.translatesAutoresizingMaskIntoConstraints = false
            cardView.addSubview(row)
            image?.layer.cornerRadius = 8
            constraints += image.map { [$0.widthAnchor.constraint(equalToConstant: 64), $0.heightAnchor.constraint(equalToConstant: 64)] } ?? []
            constraints += pin(row, top: cardView.topAnchor, topSpace: 12)
        case .captioned:
            let text = textStack(card, strings, open)
            text.translatesAutoresizingMaskIntoConstraints = false
            if let image = image {
                cardView.addSubview(image)
                constraints += [image.topAnchor.constraint(equalTo: cardView.topAnchor), image.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
                                image.trailingAnchor.constraint(equalTo: cardView.trailingAnchor), image.heightAnchor.constraint(equalToConstant: Self.imageHeight)]
            }
            cardView.addSubview(text)
            constraints += pin(text, top: image?.bottomAnchor ?? cardView.topAnchor, topSpace: image == nil ? 12 : 10)
        case .banner:
            if let image = image {
                image.accessibilityLabel = card.title
                image.isAccessibilityElement = true
                cardView.addSubview(image)
                let bottom = image.bottomAnchor.constraint(equalTo: cardView.bottomAnchor)
                bottom.priority = .defaultHigh + 249
                constraints += [image.topAnchor.constraint(equalTo: cardView.topAnchor), bottom, image.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
                                image.trailingAnchor.constraint(equalTo: cardView.trailingAnchor), image.heightAnchor.constraint(equalToConstant: Self.imageHeight)]
            } else {
                // A banner without an image: its title, so that the card is not empty.
                let text = textStack(card, strings, open)
                text.translatesAutoresizingMaskIntoConstraints = false
                cardView.addSubview(text)
                constraints += pin(text, top: cardView.topAnchor, topSpace: 12)
            }
        }

        let close = ExpandedButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)), for: .normal)
        close.tintColor = .secondaryLabel
        close.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        close.layer.cornerRadius = 13
        close.accessibilityLabel = strings.dismiss
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(for: .touchUpInside, dismiss)
        cardView.addSubview(close)
        constraints += [close.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 6), close.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -6),
                        close.widthAnchor.constraint(equalToConstant: 26), close.heightAnchor.constraint(equalToConstant: 26)]

        NSLayoutConstraint.activate(constraints)
        setRead(card.read)
    }

    func setRead(_ read: Bool) {
        self.read = read
        applyColors()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    /// Unread cards have a border in the app tint, like on the website.
    private func applyColors() {
        let border: UIColor = read ? .separator : tintColor
        cardView.layer.borderColor = border.resolvedColor(with: traitCollection).cgColor
        button?.backgroundColor = tintColor
        pinned?.textColor = tintColor
    }

    /// The text column; its right side leaves room for the remove button.
    private func pin(_ view: UIView, top: NSLayoutYAxisAnchor, topSpace: CGFloat) -> [NSLayoutConstraint] {
        let bottom = view.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12)
        bottom.priority = .defaultHigh + 249
        return [view.topAnchor.constraint(equalTo: top, constant: topSpace), bottom,
                view.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -38)]
    }

    private func makeImageView(_ url: URL) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .tertiarySystemFill
        view.translatesAutoresizingMaskIntoConstraints = false
        FeedImages.load(url) { [weak self, weak view] image in
            guard self?.imageURL == url else { return }
            view?.image = image
        }
        return view
    }

    private func textStack(_ card: OneTraceFeedCard, _ strings: FeedStrings, _ open: @escaping () -> Void) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .fill

        let title = UILabel()
        title.text = card.title
        title.numberOfLines = 0
        title.textColor = .label
        title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        title.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(title)

        if let text = card.body, card.layout != .banner {
            let body = UILabel()
            body.text = text
            body.numberOfLines = 0
            body.textColor = .secondaryLabel
            body.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 14))
            body.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(body)
        }

        if let label = card.buttonText, card.buttonURL != nil, card.layout != .banner {
            let action = UIButton(type: .system)
            action.setTitle(label, for: .normal)
            action.setTitleColor(.white, for: .normal)
            action.titleLabel?.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 14, weight: .semibold))
            action.titleLabel?.adjustsFontForContentSizeCategory = true
            action.layer.cornerRadius = 8
            action.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            action.addAction(for: .touchUpInside, open)
            button = action
            let row = UIStackView(arrangedSubviews: [action, UIView()])
            row.axis = .horizontal
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last ?? title)
            stack.addArrangedSubview(row)
        } else {
            button = nil
        }

        if card.pinned {
            let label = UILabel()
            label.text = strings.pinned
            label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 11, weight: .semibold))
            label.adjustsFontForContentSizeCategory = true
            pinned = label
            stack.setCustomSpacing(6, after: stack.arrangedSubviews.last ?? title)
            stack.addArrangedSubview(label)
        } else {
            pinned = nil
        }

        return stack
    }
}

/// The remove button: small on screen, a comfortable 44-point touch target.
private final class ExpandedButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -9, dy: -9).contains(point)
    }
}

/// Card images: `URLSession` as for in-app messages, kept in memory while the app runs.
enum FeedImages {
    private static let cache = NSCache<NSURL, UIImage>()

    static func load(_ url: URL, _ done: @escaping (UIImage) -> Void) {
        if let image = cache.object(forKey: url as NSURL) {
            done(image)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            cache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async { done(image) }
        }.resume()
    }
}
#endif
