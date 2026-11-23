#if canImport(UserNotificationsUI) && os(iOS)
import OneTracePush
import UIKit
import UserNotifications
import UserNotificationsUI

/// The Notification Content Extension of OneTrace notifications: the carousel (swipe through the cards, a tap opens the
/// card) and the countdown of the timer, shown when the user expands the notification. Subclass it in your extension
/// target, whose Info.plist lists the categories `cdp_carousel` and `cdp_timer` in `UNNotificationExtensionCategory`
/// and sets `UNNotificationExtensionUserInteractionEnabled`.
open class OneTraceNotificationContentViewController: UIViewController, UNNotificationContentExtension {
    /// The App Group shared with the app (`OneTraceConfig.appGroup`): then a tapped card opens its own link and the
    /// open is reported with it. Without it a tap opens the message link.
    open var appGroup: String? { nil }

    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let countdownLabel = UILabel()
    private let untilLabel = UILabel()
    private let pageControl = UIPageControl()
    private var imageRatio: NSLayoutConstraint?

    private var message: PushMessage?
    private var images: [Int: UIImage] = [:]
    private var index = 0
    private var ticker: Timer?

    override open func viewDidLoad() {
        super.viewDidLoad()

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        bodyLabel.font = .preferredFont(forTextStyle: .subheadline)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 3
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        countdownLabel.textAlignment = .center
        untilLabel.font = .preferredFont(forTextStyle: .footnote)
        untilLabel.textColor = .secondaryLabel
        untilLabel.textAlignment = .center
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .tertiaryLabel
        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = false

        let text = UIStackView(arrangedSubviews: [titleLabel, bodyLabel, countdownLabel, untilLabel, pageControl])
        text.axis = .vertical
        text.spacing = 4
        text.isLayoutMarginsRelativeArrangement = true
        text.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)

        let stack = UIStackView(arrangedSubviews: [imageView, text])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        setImageRatio(16.0 / 9.0)

        let left = UISwipeGestureRecognizer(target: self, action: #selector(showNext))
        left.direction = .left
        let right = UISwipeGestureRecognizer(target: self, action: #selector(showPrevious))
        right.direction = .right
        view.addGestureRecognizer(left)
        view.addGestureRecognizer(right)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openCard)))
    }

    open func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let message = PushMessage(content.userInfo)
        self.message = message
        images = [:]
        index = 0

        // Pictures attached by `OneTraceNotificationService`; the missing ones (a «remind me later» copy) are loaded here.
        for attachment in content.attachments {
            let id = attachment.identifier
            let position = id == "image" ? 0 : Int(id.dropFirst("card".count))
            guard id.hasPrefix("card") || id == "image", let at = position, let image = Self.image(attachment.url) else { continue }
            images[at] = image
        }

        if message.hasCarousel {
            pageControl.numberOfPages = message.carousel.count
            for (position, card) in message.carousel.enumerated() where images[position] == nil {
                if let url = card.image { load(url, at: position) }
            }
        } else if images[0] == nil, let url = message.image {
            load(url, at: 0)
        }

        showCard()
        startCountdown(content.title, content.body)
    }

    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ticker?.invalidate()
        ticker = nil
    }

    @objc private func showNext() {
        guard let message = message, message.hasCarousel else { return }
        index = (index + 1) % message.carousel.count
        showCard()
    }

    @objc private func showPrevious() {
        guard let message = message, message.hasCarousel else { return }
        index = (index - 1 + message.carousel.count) % message.carousel.count
        showCard()
    }

    /// A tap opens the app with the shown card: its link is handed over through the App Group.
    @objc private func openCard() {
        guard let message = message else { return }
        if message.hasCarousel, let token = message.token, let url = message.carousel[index].url,
           let group = appGroup, let defaults = UserDefaults(suiteName: group) {
            CarouselSelection.save(token: token, url: url, in: defaults)
        }
        extensionContext?.performNotificationDefaultAction()
    }

    private func showCard() {
        guard let message = message else { return }
        if message.hasCarousel {
            let card = message.carousel[index]
            titleLabel.text = card.title
            bodyLabel.text = card.body
            pageControl.currentPage = index
        } else {
            titleLabel.text = message.title
            bodyLabel.text = message.body
        }
        titleLabel.isHidden = titleLabel.text?.isEmpty ?? true
        bodyLabel.isHidden = bodyLabel.text?.isEmpty ?? true

        let image = images[index]
        imageView.image = image
        imageView.isHidden = image == nil && !message.hasCarousel
        if let image = image, image.size.width > 0, image.size.height > 0 {
            setImageRatio(max(1, min(2, image.size.width / image.size.height)))
        }
        resize()
    }

    private func startCountdown(_ title: String, _ body: String) {
        ticker?.invalidate()
        guard let end = message?.timerEnd else {
            countdownLabel.isHidden = true
            untilLabel.isHidden = true
            return
        }

        if message?.hasCarousel != true, message?.title == nil {
            titleLabel.text = title
            bodyLabel.text = body
            titleLabel.isHidden = title.isEmpty
            bodyLabel.isHidden = body.isEmpty
        }
        countdownLabel.isHidden = false
        untilLabel.isHidden = false
        untilLabel.text = TimerText.until(end)

        let tick = { [weak self] in
            guard let self = self else { return }
            if let left = TimerText.countdown(end.timeIntervalSinceNow) {
                self.countdownLabel.text = left
            } else {
                self.countdownLabel.text = PushStrings.forLanguage(nil).ended
                self.ticker?.invalidate()
            }
        }
        tick()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
        resize()
    }

    private func load(_ url: URL, at position: Int) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, data.count <= 1_048_576, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.images[position] = image
                if position == self.index { self.showCard() }
            }
        }.resume()
    }

    private func setImageRatio(_ ratio: CGFloat) {
        imageRatio?.isActive = false
        imageRatio = imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 1 / ratio)
        imageRatio?.priority = .defaultHigh
        imageRatio?.isActive = true
    }

    private func resize() {
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let size = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        preferredContentSize = CGSize(width: width, height: size.height)
    }

    private static func image(_ url: URL) -> UIImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return UIImage(contentsOfFile: url.path)
    }
}
#endif
