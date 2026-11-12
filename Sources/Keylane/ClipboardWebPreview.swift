import SwiftUI
import WebKit
import KeylaneCore

struct ClipboardWebPreview: View {
    let url: URL
    @State private var started = false
    @State private var phase = Page.Phase.loading

    var body: some View {
        ZStack {
            if started, phase != .failed {
                Page(url: url, phase: $phase).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            switch phase {
            case .loading: ProgressView().controlSize(.small).accessibilityLabel("正在加载网页")
            case .ready: EmptyView()
            case .failed:
                ContentUnavailableView {
                    Label("网页无法预览", systemImage: "globe")
                } description: {
                    Text(url.host() ?? url.absoluteString)
                } actions: {
                    Link("在浏览器中打开", destination: url)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Avoid requesting each URL while moving rapidly through clipboard history.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            started = true
        }
    }

    private struct Page: NSViewRepresentable {
        enum Phase { case loading, ready, failed }
        let url: URL
        @Binding var phase: Phase

        func makeCoordinator() -> Coordinator { Coordinator(phase: $phase) }

        func makeNSView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = context.coordinator
            view.load(URLRequest(url: url, timeoutInterval: 15))
            return view
        }

        func updateNSView(_ view: WKWebView, context: Context) {}

        static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
            view.navigationDelegate = nil
            view.stopLoading()
        }

        final class Coordinator: NSObject, WKNavigationDelegate {
            @Binding var phase: Phase
            init(phase: Binding<Phase>) { _phase = phase }

            func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                         decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
                let url = action.request.url.flatMap { ClipboardCategory.webURL(in: $0.absoluteString) }
                decisionHandler(url != nil && action.targetFrame != nil && !action.shouldPerformDownload ? .allow : .cancel)
            }

            func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                         decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
                let previewable = response.canShowMIMEType
                if !previewable, response.isForMainFrame { phase = .failed }
                decisionHandler(previewable ? .allow : .cancel)
            }

            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { phase = .ready }
            func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
            func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
            func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { phase = .failed }

            private func failed(_ error: Error) {
                if (error as NSError).code != NSURLErrorCancelled { phase = .failed }
            }
        }
    }
}
