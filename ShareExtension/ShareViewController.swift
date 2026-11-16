import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let panel = UIHostingController(rootView: SharedPlaceView(
            read: { [weak self] in await self?.readInput() },
            close: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        ))
        view.backgroundColor = .systemBackground
        addChild(panel)
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel.view)
        NSLayoutConstraint.activate([
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.topAnchor.constraint(equalTo: view.topAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        panel.didMove(toParent: self)
    }

    private func readInput() async -> String? {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
        var link: String?
        var text = items.compactMap { $0.attributedContentText?.string }.first
        for attachment in attachments {
            if link == nil, attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                link = await read(attachment, type: .url)
            }
            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                text = await read(attachment, type: .plainText) ?? text
            }
        }
        if let link {
            if let text, !text.contains("://") { return "\(text)\n\(link)" }
            return text ?? link
        }
        return text
    }

    private func read(_ attachment: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            attachment.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL: continuation.resume(returning: url.absoluteString)
                case let text as String: continuation.resume(returning: text)
                case let text as NSAttributedString: continuation.resume(returning: text.string)
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }
}

private struct SharedPlaceView: View {
    let read: @MainActor () async -> String?
    let close: () -> Void

    @State private var status = Status.loading

    private enum Status: Equatable {
        case loading, ready(String), saved, failed
    }

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .loading:
                    ProgressView("正在读取地点")
                case .ready(let text):
                    ContentUnavailableView {
                        Label("导入到别坐过站", systemImage: "mappin.circle")
                    } description: {
                        Text(text).lineLimit(3)
                    } actions: {
                        Button("导入地点") {
                            status = SharedPlaceInbox.save(text) ? .saved : .failed
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .saved:
                    ContentUnavailableView(
                        "地点已导入",
                        systemImage: "checkmark.circle",
                        description: Text("打开「别坐过站」，核对地点并开始守候。")
                    )
                case .failed:
                    ContentUnavailableView(
                        "暂时无法导入",
                        systemImage: "mappin.slash",
                        description: Text("可以复制地点或链接，再到「别坐过站」粘贴。")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("关闭", action: close) }
            }
        }
        .task {
            guard case .loading = status else { return }
            guard let text = await read()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.utf8.count <= SharedPlaceInbox.inputLimit else {
                status = .failed
                return
            }
            status = .ready(text)
        }
    }
}
