import XCTest
import AppKit
import Carbon
@testable import OpenWhisper

final class InputTests: XCTestCase {
    func testModifierShortcutRecordsOnReleaseAndRequiresTwoKeys() {
        var capture = ShortcutCapture()
        XCTAssertNil(capture.flagsChanged(.command))
        XCTAssertNil(capture.flagsChanged([.command, .control]))
        let shortcut = capture.flagsChanged(.control)
        XCTAssertEqual(shortcut, Shortcut())
        XCTAssertEqual(shortcut?.display, "⌃⌘")
        XCTAssertNil(capture.flagsChanged([]))
    }
    func testModifierTriggerFiresOncePerPressAndIgnoresOtherModifiers() {
        var trigger = ModifierShortcutTrigger(required: UInt32(cmdKey | controlKey))
        XCTAssertFalse(trigger.update(.command))
        XCTAssertTrue(trigger.update([.command, .control]))
        XCTAssertFalse(trigger.update([.command, .control, .capsLock]))
        XCTAssertFalse(trigger.update([.command, .control, .shift]))
        XCTAssertFalse(trigger.update([.command, .control]))
        XCTAssertFalse(trigger.update([]))
        XCTAssertTrue(trigger.update([.command, .control]))
    }
    func testModifierTriggerIgnoresAChordThatContainedTheShortcut() {
        // ⌘⇧⌃4 (screenshot): letting go of ⇧ passes through exactly ⌘⌃ and must not start a recording.
        var trigger = ModifierShortcutTrigger(required: UInt32(cmdKey | controlKey))
        XCTAssertFalse(trigger.update(.command))
        XCTAssertFalse(trigger.update([.command, .shift]))
        XCTAssertFalse(trigger.update([.command, .shift, .control]))
        XCTAssertFalse(trigger.update([.command, .control]))
        XCTAssertFalse(trigger.update([]))
        XCTAssertTrue(trigger.update([.command, .control]))
    }
    func testOldLetterShortcutStaysAKeyShortcut() throws {
        let data = Data("{\"keyCode\":2,\"modifiers\":6144,\"keyLabel\":\"D\"}".utf8)
        let shortcut = try JSONDecoder().decode(Shortcut.self, from: data)
        XCTAssertFalse(shortcut.isModifierOnly)
        XCTAssertEqual(shortcut.display, "⌃⌥D")
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(Shortcut())), Shortcut())
    }
    @MainActor func testDestinationIsDecidedWhenTheTextIsReadyNotAtTheStart() async {
        // No text field when recording starts: nothing is decided, and the HUD says nothing about the clipboard.
        let input = MockInput()
        var clipboard: [String] = []
        let output = TranscriptOutputService(input: input, copy: { clipboard.append($0) })
        await output.prepare()
        XCTAssertFalse(output.usesClipboard)
        XCTAssertNil(output.consumeNotice())
        // The cursor is in a field when the text is ready: it is pasted there.
        await output.deliver("测试文字。")
        XCTAssertEqual(input.pasted, ["测试文字。"])
        XCTAssertTrue(clipboard.isEmpty)
        XCTAssertEqual(input.prepared, 1)
    }
    @MainActor func testNoTextFieldWhenTheTextIsReadyLeavesItOnTheClipboard() async {
        let input = MockInput(); input.pasteError = OpenWhisperError(L("当前位置不是可编辑文本框。"))
        var clipboard: [String] = []
        let output = TranscriptOutputService(input: input, copy: { clipboard.append($0) })
        await output.prepare(); await output.deliver("测试文字。")
        XCTAssertTrue(output.usesClipboard)
        XCTAssertEqual(clipboard, ["测试文字。"])
        XCTAssertNil(output.consumeNotice(), "the HUD status line already says the text was copied")
    }
    @MainActor func testFinishedTextIsPastedOnceAndNeverReadBack() async {
        let input = MockInput()
        var clipboard: [String] = []
        let output = TranscriptOutputService(input: input, copy: { clipboard.append($0) })
        await output.prepare(); await output.deliver("你好，世界。")
        XCTAssertEqual(input.pasted, ["你好，世界。"])
        XCTAssertFalse(output.usesClipboard)
        XCTAssertTrue(clipboard.isEmpty)
    }
    @MainActor func testLiveWritingThatFailsMidwaySaysSoAndCopiesTheFinalText() async {
        let input = MockInput()
        var clipboard: [String] = []
        let output = TranscriptOutputService(input: input, copy: { clipboard.append($0) })
        await output.prepare()
        await output.appendLive("Hello")
        input.pasteError = OpenWhisperError(L("你切换了应用。"))
        await output.appendLive("Hello, world")
        XCTAssertEqual(output.consumeNotice(), L("已切换到剪贴板"))
        await output.finishLive(raw: "Hello, world.", final: "Hello, world.")
        XCTAssertEqual(clipboard, ["Hello, world."])
        XCTAssertTrue(output.usesClipboard)
    }
    @MainActor func testLiveWritingOnlyAppendsAndStopsAtARevision() async {
        let input = MockInput()
        var clipboard: [String] = []
        let output = TranscriptOutputService(input: input, copy: { clipboard.append($0) })
        await output.prepare()
        await output.appendLive("你好")
        await output.appendLive("你好世界")
        await output.appendLive("你好，世界")   // revises written text: nothing is deleted, live writing stops
        await output.appendLive("你好，世界。我们")
        await output.finishLive(raw: "你好，世界。", final: "你好，世界。")
        XCTAssertEqual(input.pasted, ["你好", "世界"])
        XCTAssertEqual(clipboard, ["你好，世界。"])
        XCTAssertEqual(output.consumeNotice(), L("识别有修正，完整文字已复制到剪贴板"))
    }
    @MainActor func testLiveWritingCompletesTheRawTextAndCopiesTheCleanedUpVersion() async {
        let input = MockInput()
        var clipboard: [String] = []
        let output = TranscriptOutputService(input: input, copy: { clipboard.append($0) })
        await output.prepare()
        await output.appendLive("我们用过你和 ")
        await output.finishLive(raw: "我们用过你和来训练", final: "我们用过拟合来训练。")
        XCTAssertEqual(input.pasted, ["我们用过你和", "来训练"])
        XCTAssertEqual(clipboard, ["我们用过拟合来训练。"])
        XCTAssertEqual(output.consumeNotice(), L("整理后的文字已复制到剪贴板"))
        // Unchanged by cleanup: nothing more to do.
        let plain = MockInput(); var copied: [String] = []
        let same = TranscriptOutputService(input: plain, copy: { copied.append($0) })
        await same.prepare(); await same.appendLive("Hello"); await same.finishLive(raw: "Hello world", final: "Hello world")
        XCTAssertEqual(plain.pasted, ["Hello", " world"]); XCTAssertTrue(copied.isEmpty); XCTAssertNil(same.consumeNotice())
    }
    @MainActor func testLiveWritingWithNothingWrittenPastesTheCleanedUpText() async {
        let input = MockInput()
        let output = TranscriptOutputService(input: input, copy: { _ in XCTFail("nothing to copy") })
        await output.prepare()
        await output.appendLive("")
        await output.finishLive(raw: "hello world", final: "Hello world.")
        XCTAssertEqual(input.pasted, ["Hello world."])
    }
    func testLiveAppendHoldsBackTrailingSpaceAndIgnoresRetractions() {
        var live = LiveAppend()
        XCTAssertEqual(live.next("Hello "), "Hello")
        XCTAssertNil(live.next(""), "a retracted noise guess is not a revision")
        XCTAssertEqual(live.next("Hello world"), " world")
        XCTAssertNil(live.next("Hello world "))
        XCTAssertNil(live.next("Hello word"))
        XCTAssertTrue(live.stopped)
        XCTAssertNil(live.next("Hello world again"), "stays stopped for the rest of the dictation")
    }
    @MainActor func testPasteboardIsLentAndGivenBack() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("user's own text", forType: .string)
        var presses = 0
        let keeper = PasteboardKeeper(board: board, delay: .milliseconds(40)) { presses += 1 }
        keeper.paste("dictation")
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(board.string(forType: .string), "dictation")
        XCTAssertNotNil(board.data(forType: PasteboardKeeper.transient), "clipboard history apps skip it")
        keeper.paste("dictation, more")   // a second paste keeps the user's text, not the first dictation
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(board.string(forType: .string), "user's own text")
        // Something copied in the meantime wins over the restore.
        keeper.paste("again")
        board.clearContents(); board.setString("copied meanwhile", forType: .string)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(board.string(forType: .string), "copied meanwhile")
    }
    @MainActor func testSlowOutputCoalescesPartialsAndFlushesTheFinalRevision() async {
        var written: [String] = []
        var unblock: CheckedContinuation<Void, Never>?
        let delivery = StreamingTextDelivery { text in
            written.append(text)
            if written.count == 1 { await withCheckedContinuation { unblock = $0 } }
        }
        delivery.submit("你")
        while unblock == nil { await Task.yield() }
        delivery.submit("你好")
        delivery.submit("你好，世界")
        let final = Task { await delivery.finish("你好，世界。") }
        await Task.yield()
        unblock?.resume()
        await final.value
        XCTAssertEqual(written, ["你", "你好，世界。"])
    }
    @MainActor func testAPasteThatFailsAfterANewDictationStartedCannotCopyIntoIt() async {
        let input = MockInput()
        var pending: CheckedContinuation<Void, Error>?
        input.onPaste = { try await withCheckedThrowingContinuation { pending = $0 } }
        var clipboard: [String] = []
        let output = TranscriptOutputService(input: input, copy: { clipboard.append($0) })
        await output.prepare()
        let old = Task { await output.deliver("old dictation") }
        while pending == nil { await Task.yield() }
        output.reset(); input.onPaste = nil
        await output.prepare()
        pending?.resume(throwing: OpenWhisperError("old field gone"))
        await old.value
        XCTAssertTrue(clipboard.isEmpty)
        XCTAssertFalse(output.usesClipboard)
        await output.deliver("new dictation")
        XCTAssertEqual(input.pasted.last, "new dictation")
    }
    @MainActor func testHUDNoticeExpiryCannotClearANewerNotice() async throws {
        let notice = HUDNotice()
        notice.show("old", duration: .milliseconds(20))
        await Task.yield()
        notice.show("new", duration: .seconds(1))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(notice.text, "new")
        // Generous margin: the expiry task can run late on a busy machine.
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertNil(notice.text)
        notice.show("cancelled")
        notice.clear()
        XCTAssertNil(notice.text)
    }
}

@MainActor private final class MockInput: TranscriptTextInput {
    var targetName = "Test editor"
    var pasteError: Error?
    var pasted: [String] = []
    var prepared = 0
    var onPaste: (() async throws -> Void)?
    func prepare() async { prepared += 1 }
    func paste(_ text: String, live: Bool) async throws {
        try await onPaste?()
        if let pasteError { throw pasteError }
        pasted.append(text)
    }
    func reset() {}
}
