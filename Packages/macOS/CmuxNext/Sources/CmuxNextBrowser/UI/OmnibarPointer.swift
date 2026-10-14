public import AppKit
import CmuxNextDesign

/// Pointer rules of the browser toolbar and its omnibar (cx-d0d.80). Every
/// view that sets a cursor or a hover in the toolbar follows them; the
/// live check `scripts/cmux-next/omnibar-pointer-live.py` walks them.
///
/// Cursor:
/// - I-beam over the bar's text area (`AddressBarView.textArea`: from the
///   page-info chip to the first trailing badge, the bar's full height),
///   at rest and while editing, as in Safari and Chrome (Lawrence
///   2026-10-13). The same rectangle takes the press that focuses the
///   field, so wherever the I-beam shows, a click focuses.
/// - Arrow everywhere else in the toolbar: the bar beside the chip and the
///   badges, the page-info chip, the badges, the star and every button. A
///   toolbar control is not a link, so it never shows the pointing hand.
/// - The toolbar row sets the arrow over its whole frame, so a cursor the
///   page set (a link's hand, a text I-beam) never stays when the pointer
///   moves up into the toolbar, and no edge between two rects shows a stale
///   cursor.
///
/// Hover:
/// - One treatment: a theme-token fill (`Palette.hoverFill`, the pill's
///   lift `OmnibarStyle.barHoverFill`) that eases in and clears at once
///   (`ChromeHover.fade`), so a sweep across the buttons leaves no trail.
/// - Hover is where the pointer is now (`PointerHover`), recomputed when the
///   view hides, shows or changes window: a tab switch, a parked pane or a
///   collapsed button under a still pointer leaves no hover behind.
/// - A disabled control and the bar while it edits show no hover.
///
/// Focus (the omnibar state machine, `OmnibarReducer`, owns the rules):
/// the first click anywhere in the bar focuses it and selects the whole
/// address; a second click places the caret; Cmd-L focuses and selects;
/// Escape reverts typed text, and Escape with nothing typed returns the
/// keyboard to the page. Text fields draw no focus ring of their own: the
/// pill's editing ring is the one focus look (cx-ncc.57).
enum OmnibarPointer {
    /// Where the pointer is, as far as the cursor rules care.
    enum Region: String, Sendable {
        /// The omnibar's text.
        case text
        /// The bar around the text inside the text area (above and below
        /// the line, past its end).
        case bar
        /// The bar outside the text area (beside the chip and the badges).
        case barEdge
        /// A chip, badge, star or button.
        case control
        /// The toolbar row outside the bar and its buttons.
        case toolbar
    }

    enum Cursor: String, Sendable {
        case arrow
        case iBeam

        var cursor: NSCursor { self == .iBeam ? .iBeam : .arrow }
    }

    /// The cursor for `region`, the same at rest and while editing.
    static func cursor(_ region: Region) -> Cursor {
        region == .text || region == .bar ? .iBeam : .arrow
    }
}

/// A toolbar row that shows the arrow over its whole frame and the I-beam
/// over the omnibar's text area (`OmnibarPointer`).
///
/// Cursor rects work only in the key window. A Chromium page is a child
/// window that takes the key while the page has the keyboard
/// (`WindowKeyFamily`), so the toolbar's rects did nothing and the arrow
/// stayed over the omnibar until a click made the parent key (Lawrence
/// 2026-10-13). The row also sets the cursor itself on every pointer move
/// over it, with a tracking area that works in any window state. The rects
/// stay for the key window; subviews with their own rects (the editing
/// omnibar text) take precedence inside it.
public class ArrowCursorView: NSView {
    private var cursorArea: NSTrackingArea?
    /// Owns the row's cursor tracking area, so the area's events end there
    /// and never travel up the responder chain (a tracking area keeps its
    /// owner unretained).
    private let cursorTracker = RowCursorTracker()
    /// The cursor the row last set on a pointer move (`debug.omnibar`).
    private(set) var trackedCursor: OmnibarPointer.Cursor?

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: OmnibarPointer.cursor(.toolbar).cursor)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // `.inVisibleRect` follows the view's visible rect: one area is enough.
        guard cursorArea == nil else { return }
        cursorTracker.row = self
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: cursorTracker)
        addTrackingArea(area)
        cursorArea = area
    }

    /// Call after the app handled a pointer move (`NSApplication.sendEvent`). While a child
    /// window (a Chromium page) has the key, AppKit sets the arrow for every move outside the
    /// key window, after the row's own tracking event: the toolbar row under the pointer in a
    /// window that is not key sets its cursor again, last. Cheap when the key window is a
    /// top-level window: one property read.
    public static func pointerDidMove() {
        guard NSApp.isActive, let key = NSApp.keyWindow, key.parent != nil else { return }
        let location = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)
        guard number != key.windowNumber, let window = NSApp.window(withWindowNumber: number),
              let frame = window.contentView?.superview ?? window.contentView else { return }
        // The frame view sits at the window's origin: window coordinates are its superview's.
        let point = window.convertPoint(fromScreen: location)
        guard let hit = frame.hitTest(point),
              let row = sequence(first: hit, next: \.superview).lazy.compactMap({ $0 as? ArrowCursorView }).first else { return }
        row.setCursor(at: point)
    }

    fileprivate func setCursor(at point: NSPoint) {
        let cursor = OmnibarPointer.cursor(atWindowPoint: point, in: self)
        trackedCursor = cursor
        cursor.cursor.set()
    }
}

/// The owner of `ArrowCursorView`'s cursor tracking area: an enter, a move
/// or a cursor update sets the row's cursor; nothing goes further.
private final class RowCursorTracker: NSResponder {
    weak var row: ArrowCursorView?

    override func mouseEntered(with event: NSEvent) { row?.setCursor(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { row?.setCursor(at: event.locationInWindow) }
    override func cursorUpdate(with event: NSEvent) { row?.setCursor(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {}
}

extension OmnibarPointer {
    /// The cursor at a window point over `row`: the I-beam inside an
    /// omnibar's text area (the rectangle of its cursor rects), the arrow
    /// everywhere else in the row.
    @MainActor
    static func cursor(atWindowPoint point: NSPoint, in row: NSView) -> Cursor {
        guard let parent = row.superview, let hit = row.hitTest(parent.convert(point, from: nil)) else { return cursor(.toolbar) }
        let bar = sequence(first: hit, next: \.superview).prefix(while: { $0 !== row }).lazy.compactMap { $0 as? AddressBarView }.first
        guard let bar else { return cursor(.toolbar) }
        return bar.textArea.contains(bar.convert(point, from: nil)) ? cursor(.bar) : cursor(.barEdge)
    }
}
