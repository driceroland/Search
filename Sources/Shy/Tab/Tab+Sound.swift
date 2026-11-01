import Combine
import ImageIO
import SwiftUI
import WebKit

// Sound: a tab heard, hushed and given back to the media keys.
extension Tab {
    /// The page's sound started or stopped. Stopped, after it had played,
    /// one timer counts down; started again, or the page gone, it is dropped.
    func heard(_ on: Bool) {
        let was = noisy
        noisy = on
        quiet?.invalidate()
        quiet = nil
        guard was, !on else { return }
        quiet = Timer.scheduledTimer(withTimeInterval: MediaKeys.wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hush() }
        }
    }

    /// The page is going: its count and its frames with it.
    func leaving() {
        quiet?.invalidate()
        quiet = nil
        media.forget()
    }

    /// Quiet long enough: the paused media muted, in the page and in each
    /// frame that played, so the Mac hands the media keys back.
    private func hush() {
        quiet = nil
        guard !noisy, let built else { return }
        built.quietly(MediaKeys.hush)
        for frame in media.frames {
            built.quietly(MediaKeys.hush, in: frame)
        }
    }

    /// The view and everything listening to it, gone — timers, video,
    /// sockets, and the document WebKit would otherwise keep in its
    /// back-forward cache. The tab keeps its address; `web` builds again the
    /// next time anyone asks for it.
    func discard() {
        popupGesture.clear()
        if !blockedPopups.isEmpty { blockedPopups = [] }
        translationGone(sleeping: true)
        watch = []
        ears.stop()
        quiet?.invalidate()
        quiet = nil
        let playing = media.frames
        media.forget()
        guard let web = built else { return }
        (delegate as? Browser)?.cancelDisplay(for: web)
        built = nil
        Passkeys.shared.forget(web)
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.removeAllUserScripts()
        // Other extension tabs still use this controller. Their existing
        // listeners need the relay, and their next documents need its script.
        if #available(macOS 15.4, *), Extensions.isPages(controller) {
            PopupGestureRelay.install(on: controller)
            controller.addUserScript(PopupGestureRelay.userScript)
        }
        web.onMenuClosed = nil
        web.onPull = nil
        web.leave = nil
        web.onTouch = nil
        web.onKeys = nil
        web.searchName = nil
        web.translating = nil
        web.onTranslate = nil
        web.onSearch = nil
        web.stopLoading()
        // A view that something still holds goes on playing once detached:
        // stopped here, and any picture-in-picture or full screen closed.
        // The view's own teardown takes seconds to reach the web process, and
        // the sound runs on until it does: so the media is muted and paused in
        // the page and its playing frames first, which lands at once.
        let silence = "document.querySelectorAll('video,audio').forEach(m => { m.muted = true; m.pause() }); 0"
        web.quietly(silence)
        for frame in playing {
            web.quietly(silence, in: frame)
        }
        web.pauseAllMediaPlayback()
        web.setAllMediaPlaybackSuspended(true)
        web.closeAllMediaPresentations()
        // Detaching a view doesn't end capture while something still holds it.
        web.setCameraCaptureState(.none, completionHandler: nil)
        web.setMicrophoneCaptureState(.none, completionHandler: nil)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
    }
}
