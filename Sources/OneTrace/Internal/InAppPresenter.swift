#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Shows in-app messages on the main thread over the key window, one at a time: a centered card (`modal`), a strip at
/// the top or bottom (`banner`, hides itself after a few seconds) or the whole screen (`fullscreen`). Built in code;
/// shown, button tap and close are reported through `report`.
final class InAppPresenter {
    private let openLinks: Bool
    private let report: (_ token: String, _ event: String, _ url: String?) -> Void
    private var waiting: [[String: Any]] = []
    private var overlay: UIView?
    private static let bannerSeconds = 8.0

    init(openLinks: Bool, report: @escaping (_ token: String, _ event: String, _ url: String?) -> Void) {
        self.openLinks = openLinks
        self.report = report
    }

    /// Any thread: the message is shown as soon as the app is active and no other message is on screen.
    func present(_ message: [String: Any]) {
        DispatchQueue.main.async {
            self.waiting.append(message)
            self.showNext()
        }
    }

    /// Main thread: the app became active.
    func showNext() {
        guard overlay == nil, !waiting.isEmpty, UIApplication.shared.applicationState == .active, let window = Self.keyWindow() else { return }

        let message = waiting.removeFirst()
        let token = message["token"] as? String ?? ""
        let layout = message["layout"] as? String ?? "modal"
        let background = Self.color(message["background_color"], .white)
        let text = Self.color(message["text_color"], UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1))

        let container = UIView(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = layout == "modal" ? UIColor.black.withAlphaComponent(0.4) : .clear
        if layout == "banner" { container.isUserInteractionEnabled = true }

        let card = UIView()
        card.backgroundColor = background
        card.layer.cornerRadius = layout == "fullscreen" ? 0 : 16
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        if let link = message["image_url"] as? String, let url = URL(string: link), link.hasPrefix("http") {
            let image = UIImageView()
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            image.layer.cornerRadius = 8
            image.heightAnchor.constraint(equalToConstant: layout == "banner" ? 64 : 200).isActive = true
            stack.addArrangedSubview(image)
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let picture = UIImage(data: data) else { return }
                DispatchQueue.main.async { image.image = picture }
            }.resume()
        }

        if let title = message["title"] as? String, !title.isEmpty {
            let label = UILabel()
            label.text = title
            label.textColor = text
            label.font = .boldSystemFont(ofSize: layout == "banner" ? 16 : 20)
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }

        if let body = message["body"] as? String, !body.isEmpty {
            let label = UILabel()
            label.text = body
            label.textColor = text
            label.font = .systemFont(ofSize: layout == "banner" ? 14 : 16)
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 8
        buttons.alignment = .center
        buttons.addArrangedSubview(UIView())

        let close = UIButton(type: .system)
        close.setTitle((message["close_text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "✕", for: .normal)
        close.setTitleColor(text, for: .normal)
        close.accessibilityLabel = "close"
        close.addAction(for: .touchUpInside) { [weak self] in
            self?.report(token, "dismissed", nil)
            self?.hide()
        }
        buttons.addArrangedSubview(close)

        if let label = message["button_text"] as? String, !label.isEmpty {
            let link = (message["button_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let action = UIButton(type: .system)
            action.setTitle(label, for: .normal)
            action.setTitleColor(Self.color(message["button_text_color"], .white), for: .normal)
            action.backgroundColor = Self.color(message["button_color"], UIColor(red: 0.31, green: 0.27, blue: 0.9, alpha: 1))
            action.layer.cornerRadius = 10
            action.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
            action.addAction(for: .touchUpInside) { [weak self] in
                guard let self = self else { return }
                self.report(token, "clicked", link)
                self.hide()
                if self.openLinks, let link = link, let url = URL(string: link) { UIApplication.shared.open(url) }
            }
            buttons.addArrangedSubview(action)
        }

        stack.addArrangedSubview(buttons)
        container.addSubview(card)

        let guide = container.safeAreaLayoutGuide
        var constraints = [
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ]

        switch layout {
        case "fullscreen":
            constraints += [card.topAnchor.constraint(equalTo: container.topAnchor), card.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                            card.leadingAnchor.constraint(equalTo: container.leadingAnchor), card.trailingAnchor.constraint(equalTo: container.trailingAnchor)]
            constraints[0] = stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 20)
            constraints.append(stack.centerYAnchor.constraint(equalTo: card.centerYAnchor))
            constraints[3] = stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -20)
        case "banner":
            constraints += [card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12), card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
                            (message["position"] as? String) == "top"
                                ? card.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8)
                                : card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8)]
        default:
            constraints += [card.centerYAnchor.constraint(equalTo: guide.centerYAnchor), card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
                            card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20)]
        }

        NSLayoutConstraint.activate(constraints)

        // A banner does not block the app: touches outside the card go through.
        let host: UIView = layout == "banner" ? PassThroughView(frame: window.bounds, card: card, container: container) : container
        window.addSubview(host)
        overlay = host
        report(token, "shown", nil)

        if layout == "banner" {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerSeconds) { [weak self, weak host] in
                if let host = host, self?.overlay === host { self?.hide() }
            }
        }
    }

    private func hide() {
        overlay?.removeFromSuperview()
        overlay = nil
        showNext()
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private static func color(_ value: Any?, _ fallback: UIColor) -> UIColor {
        guard let hex = value as? String, hex.count == 7, hex.hasPrefix("#"), let number = Int(hex.dropFirst(), radix: 16) else { return fallback }
        return UIColor(red: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255, blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    }
}

/// A full-window host for a banner that only catches touches on the banner itself.
private final class PassThroughView: UIView {
    private weak var card: UIView?

    init(frame: CGRect, card: UIView, container: UIView) {
        self.card = card
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.frame = bounds
        addSubview(container)
    }

    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let card = card else { return false }
        return card.bounds.contains(convert(point, to: card))
    }
}

private extension UIControl {
    /// A closure target action on iOS 13 (UIAction arrived in iOS 14).
    func addAction(for events: UIControl.Event, _ handler: @escaping () -> Void) {
        let target = ClosureTarget(handler)
        addTarget(target, action: #selector(ClosureTarget.fire), for: events)
        objc_setAssociatedObject(self, Unmanaged.passUnretained(target).toOpaque(), target, .OBJC_ASSOCIATION_RETAIN)
    }
}

private final class ClosureTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}
#endif
