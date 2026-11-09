#if canImport(SwiftUI) && canImport(UIKit) && os(iOS)
import SwiftUI

/// The message feed screen for SwiftUI: `OneTraceFeedViewController` inside a view.
///
/// ```swift
/// NavigationView {
///     OneTraceFeedView().navigationBarTitle(Text(OneTraceFeedView.title()), displayMode: .inline)
/// }
/// ```
public struct OneTraceFeedView: UIViewControllerRepresentable {
    private let language: String?

    /// - Parameter language: the labels language (`de`, `pt-BR`…); nil — the device language.
    public init(language: String? = nil) {
        self.language = language
    }

    public func makeUIViewController(context: Context) -> OneTraceFeedViewController {
        OneTraceFeedViewController(language: language)
    }

    public func updateUIViewController(_ controller: OneTraceFeedViewController, context: Context) {}

    /// The screen title, «Updates» in the device language or `language`.
    public static func title(language: String? = nil) -> String {
        FeedStrings.forLanguage(language).title
    }
}
#endif
