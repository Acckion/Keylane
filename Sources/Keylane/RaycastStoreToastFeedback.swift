import KeylaneCore

/// A separate instance of the standard toast presenter so an extension cannot
/// replace a native permission/error announcement or use its action controls.
@MainActor
final class RaycastStoreToastFeedback {
    private let presenter = ToastPresenter()
    private var state = RaycastStoreToastState()

    func apply(_ ticket: StoreGuestRunTicket, payload: String) throws -> String {
        let ticketID = ticket.id
        // The broker holds synchronous authority throughout this call. Do not
        // reenter it from the presentation reducer or dispatch work to apply later.
        try ticket.observeFeedbackEnd { [weak self] keepFinalPresentation in
            guard let self, self.state.finish(ticketID) else { return }
            if !keepFinalPresentation { self.presenter.hide() }
        }
        let feedback = try state.apply(payload, from: ticketID)
        let style: ToastStyle
        switch feedback.style {
        case .success: style = .success
        case .failure: style = .failure
        case .animated: style = .neutral
        }
        let text = ["Raycast 扩展 · " + feedback.title, feedback.message].compactMap { $0 }.joined(separator: "\n")
        presenter.show(text, style: style)
        return ""
    }
}
