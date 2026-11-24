import Foundation
import SwiftUI

/// The Memory inspector drawer tool's state: a tab per inspected buffer,
/// each reading a page of bytes at a time from the page with
/// `Runtime.callFunctionOn`, and writing edited bytes back the same way.
/// One per DevTools session.
///
/// A Console value lives in the Console's object group and a paused
/// scope's in the debugger's, which goes as soon as the page resumes. So
/// the inspector takes its own reference, in its own group, for as long as
/// the tab is open: the object is parked for a moment in a slot on the
/// page's global (under a symbol), taken out again by `Runtime.evaluate`
/// with the inspector's object group, and the slot emptied. Closing the tab
/// releases it, as clearing the Console releases the Console's.
@MainActor
final class DeveloperMemoryInspectorModel: ObservableObject, DeveloperSessionModel {
    struct Buffer: Identifiable, Equatable {
        let id = UUID()
        var title: String
        let className: String
        let kind: DeveloperMemoryInspectable.Kind
        /// The object id the inspector reads through.
        var objectId: String
        /// True when the id is the inspector's own, to release on close.
        var owned: Bool
        let targetID: String?
        /// The page the object came from; another page means it's gone.
        let address: URL?
        /// The whole underlying buffer's size.
        var length = 0
        /// A view's own bytes within it: highlighted, as in Chrome.
        var regionStart = 0
        var regionLength = 0
        var selected = 0
        var pageStart = 0
        var bytes: [UInt8] = []
        var history = DeveloperMemoryHistory()
        var problem: String?
        /// The page's own number for the memory underneath (an ArrayBuffer,
        /// or a WebAssembly.Memory): views on it share one tab, as in Chrome.
        var identity: Int?
    }

    @Published private(set) var buffers: [Buffer] = []
    @Published var selectedID: UUID?
    @Published var layout = DeveloperMemoryLayout()
    @Published var endianness = DeveloperMemoryValue.Endianness.little
    @Published var integerMode = DeveloperMemoryValue.IntegerMode.decimal
    @Published var formats: [DeveloperMemoryValue.Format] = DeveloperMemoryValue.Format.allCases
    @Published private(set) var problem: String?

    static let objectGroup = "perch-memory-inspector"

    private weak var session: DeveloperToolsSession?
    private var poll: Task<Void, Never>?
    private var reading = Set<UUID>()

    static func model(for session: DeveloperToolsSession) -> DeveloperMemoryInspectorModel {
        DeveloperSessionModels.model(for: session, make: DeveloperMemoryInspectorModel.init)
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
    }

    func sessionClosed() { stop() }

    var selected: Buffer? { buffers.first { $0.id == selectedID } ?? buffers.last }

    // MARK: Opening

    /// "Reveal in Memory inspector": a tab for the object (or the tab
    /// already open on it), with the drawer brought up at the tool.
    static func reveal(session: DeveloperToolsSession, objectId: String, targetID: String?, className: String?,
                       description: String?) {
        guard let className, let kind = DeveloperMemoryInspectable.kind(className: className) else { return }
        DeveloperToolsShell.shared.showDrawer(.tool(.memoryInspector))
        model(for: session).open(objectId: objectId, targetID: targetID, className: className, kind: kind,
                                 description: description)
    }

    private func open(objectId: String, targetID: String?, className: String, kind: DeveloperMemoryInspectable.Kind,
                      description: String?) {
        guard let session, session.ready else {
            problem = "DevTools isn’t connected to the page."
            return
        }
        problem = nil
        Task { [weak self] in
            do {
                let held = try await Self.hold(session, objectId: objectId, targetID: targetID)
                guard let self else { return }
                // The tab already on this memory: the new view's bytes highlighted in it.
                let index = held.identity.flatMap { identity in
                    self.buffers.firstIndex { $0.identity == identity && $0.targetID == targetID && $0.address == session.address }
                }
                if index != nil, held.owned { self.release(held.objectId, targetID: targetID) }
                var buffer = index.map { self.buffers[$0] }
                    ?? Buffer(title: "", className: className, kind: kind, objectId: held.objectId, owned: held.owned,
                              targetID: targetID, address: session.address, identity: held.identity)
                buffer.title = Self.title(description, className: className)
                buffer.length = held.length
                buffer.regionStart = held.offset
                buffer.regionLength = held.size
                buffer.selected = DeveloperMemoryLayout.clamp(held.offset, length: held.length)
                buffer.pageStart = self.layout.pageStart(buffer.selected)
                buffer.history.visit(buffer.selected)
                if let index { self.buffers[index] = buffer } else { self.buffers.append(buffer) }
                self.selectedID = buffer.id
                self.read(buffer.id)
            } catch {
                self?.problem = error.localizedDescription
            }
        }
    }

    private static func title(_ description: String?, className: String) -> String {
        let text = (description ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? className : String(text.prefix(60))
    }

    private struct Held {
        let objectId: String
        let owned: Bool
        let length: Int
        let offset: Int
        let size: Int
        var identity: Int?
    }

    /// The object parked, taken back into the inspector's own group, and
    /// its sizes read. If the page's global can't be reached from the main
    /// frame (an object from another frame), the original id is used.
    private static func hold(_ session: DeveloperToolsSession, objectId: String, targetID: String?) async throws -> Held {
        let info = try await session.command("Runtime.callFunctionOn", [
            "objectId": objectId, "functionDeclaration": holdFunction, "returnByValue": true,
            "doNotPauseOnExceptionsAndMuteConsole": true,
        ], targetID: targetID)
        if info["wasThrown"] as? Bool == true {
            throw DeveloperMemoryInspectorError("The object can’t be inspected.")
        }
        guard let value = (info["result"] as? [String: Any])?["value"] as? [String: Any],
              let slot = (value["slot"] as? NSNumber)?.intValue else {
            throw DeveloperMemoryInspectorError("The object is no longer available.")
        }
        let length = (value["length"] as? NSNumber)?.intValue ?? 0
        let offset = (value["offset"] as? NSNumber)?.intValue ?? 0
        let size = (value["size"] as? NSNumber)?.intValue ?? length
        let identity = (value["identity"] as? NSNumber)?.intValue
        let taken = try? await session.command("Runtime.evaluate", [
            "expression": "(() => { const h = globalThis[Symbol.for('perch.memoryInspector')]; if (!h) return undefined; const o = h.slots.get(\(slot)); h.slots.delete(\(slot)); return o; })()",
            "objectGroup": objectGroup, "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
        ], targetID: targetID)
        // The slot emptied either way.
        _ = try? await session.command("Runtime.callFunctionOn", [
            "objectId": objectId, "arguments": [["value": slot]], "doNotPauseOnExceptionsAndMuteConsole": true,
            "functionDeclaration": "function(slot) { const h = globalThis[Symbol.for('perch.memoryInspector')]; if (h) h.slots.delete(slot); }",
        ], targetID: targetID)
        if let id = (taken?["result"] as? [String: Any])?["objectId"] as? String {
            return Held(objectId: id, owned: true, length: length, offset: offset, size: size, identity: identity)
        }
        return Held(objectId: objectId, owned: false, length: length, offset: offset, size: size, identity: identity)
    }

    // MARK: Closing

    func close(_ id: UUID) {
        guard let index = buffers.firstIndex(where: { $0.id == id }) else { return }
        let buffer = buffers.remove(at: index)
        if selectedID == id { selectedID = buffers.isEmpty ? nil : buffers[max(0, index - 1)].id }
        if buffer.owned { release(buffer.objectId, targetID: buffer.targetID) }
    }

    private func release(_ objectId: String, targetID: String?) {
        guard let session else { return }
        Task { _ = try? await session.command("Runtime.releaseObject", ["objectId": objectId], targetID: targetID) }
    }

    // MARK: Reading

    /// While shown: the selected tab read again every second, as the page
    /// may change its bytes at any time (Chrome reads again on each pause).
    func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            // Ends with the model, not only on stop().
            while !Task.isCancelled {
                guard let self else { return }
                if let id = self.selected?.id { self.read(id) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    func refresh() {
        if let id = selected?.id { read(id) }
    }

    private func read(_ id: UUID) {
        guard let session, let buffer = buffers.first(where: { $0.id == id }), !reading.contains(id) else { return }
        if buffer.address != session.address {
            update(id) { $0.problem = "The page has navigated; this buffer is gone. Close the tab." }
            return
        }
        guard buffer.problem == nil || buffer.length > 0 else { return }
        reading.insert(id)
        let start = buffer.pageStart
        let count = layout.pageSize + 8
        Task { [weak self] in
            defer {
                // Moved to another page meanwhile: that one is read now.
                self?.reading.remove(id)
                if let moved = self?.buffers.first(where: { $0.id == id }), moved.pageStart != start { self?.read(id) }
            }
            do {
                let reply = try await session.command("Runtime.callFunctionOn", [
                    "objectId": buffer.objectId, "functionDeclaration": Self.readFunction,
                    "arguments": [["value": start], ["value": count]], "returnByValue": true,
                    "doNotPauseOnExceptionsAndMuteConsole": true,
                ], targetID: buffer.targetID)
                guard let value = (reply["result"] as? [String: Any])?["value"] as? [String: Any] else {
                    throw DeveloperMemoryInspectorError("The buffer is no longer available.")
                }
                let length = (value["length"] as? NSNumber)?.intValue ?? 0
                let bytes = DeveloperMemoryBytes.decode(value["bytes"]) ?? []
                let detached = (value["detached"] as? NSNumber)?.boolValue ?? false
                self?.update(id) { buffer in
                    buffer.length = length
                    if buffer.pageStart == start { buffer.bytes = bytes }
                    buffer.problem = detached ? "The ArrayBuffer has been detached." : nil
                    if length > 0, buffer.selected >= length {
                        buffer.selected = length - 1
                        buffer.pageStart = self?.layout.pageStart(length - 1) ?? 0
                    }
                }
            } catch {
                self?.update(id) { $0.problem = error.localizedDescription }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Buffer) -> Void) {
        guard let index = buffers.firstIndex(where: { $0.id == id }) else { return }
        var buffer = buffers[index]
        change(&buffer)
        if buffer != buffers[index] { buffers[index] = buffer }
    }

    // MARK: Navigating

    /// A byte clicked: selected, the page kept.
    func select(_ address: Int) {
        guard let id = selected?.id else { return }
        update(id) { buffer in
            buffer.selected = DeveloperMemoryLayout.clamp(address, length: buffer.length)
            buffer.history.visit(buffer.selected)
        }
    }

    /// The address field, or a pointer followed: the byte selected and
    /// its page shown. False when the address is outside the buffer.
    @discardableResult
    func go(to address: Int, record: Bool = true) -> Bool {
        guard let current = selected, address >= 0, address < max(current.length, 1) else { return false }
        let page = layout.pageStart(address)
        update(current.id) { buffer in
            buffer.selected = address
            if buffer.pageStart != page {
                buffer.pageStart = page
                buffer.bytes = []
            }
            if record { buffer.history.visit(address) }
        }
        read(current.id)
        return true
    }

    func step(pages: Int) {
        guard let current = selected else { return }
        go(to: layout.step(current.selected, pages: pages, length: current.length))
    }

    func back() { travel { $0.back() } }
    func forward() { travel { $0.forward() } }

    private func travel(_ move: (inout DeveloperMemoryHistory) -> Int?) {
        guard let id = selected?.id, let index = buffers.firstIndex(where: { $0.id == id }) else { return }
        if let address = move(&buffers[index].history) { go(to: address, record: false) }
    }

    /// The view reflowed to a width: rows of a new size, the page kept on
    /// the selected byte.
    func setBytesPerRow(_ count: Int) {
        guard count != layout.bytesPerRow, count > 0 else { return }
        layout.bytesPerRow = count
        for buffer in buffers {
            update(buffer.id) { $0.pageStart = layout.pageStart($0.selected); $0.bytes = [] }
        }
        refresh()
    }

    // MARK: Editing

    /// A byte typed over: written into the page's buffer, then read back.
    func write(_ address: Int, value: UInt8) {
        guard let session, let buffer = selected, address >= 0, address < buffer.length else { return }
        let id = buffer.id
        if address >= buffer.pageStart, address - buffer.pageStart < buffer.bytes.count {
            update(id) { $0.bytes[address - $0.pageStart] = value }
        }
        Task { [weak self] in
            do {
                let reply = try await session.command("Runtime.callFunctionOn", [
                    "objectId": buffer.objectId, "functionDeclaration": Self.writeFunction,
                    "arguments": [["value": address], ["value": [Int(value)]]], "returnByValue": true,
                    "doNotPauseOnExceptionsAndMuteConsole": true,
                ], targetID: buffer.targetID)
                if reply["wasThrown"] as? Bool == true {
                    throw DeveloperMemoryInspectorError("The byte couldn’t be written.")
                }
            } catch {
                self?.update(id) { $0.problem = error.localizedDescription }
            }
            self?.read(id)
        }
    }

    // MARK: Page functions

    /// Run on the inspected object: it parked in a slot, and its sizes.
    private static let holdFunction = """
        function() {
            const key = Symbol.for("perch.memoryInspector");
            let holder = globalThis[key];
            if (!holder) {
                holder = {next: 0, slots: new Map(), ids: new WeakMap(), nextID: 0};
                Object.defineProperty(globalThis, key, {value: holder, configurable: true, enumerable: false});
            }
            const slot = ++holder.next;
            holder.slots.set(slot, this);
            const tag = Object.prototype.toString.call(this).slice(8, -1);
            const view = ArrayBuffer.isView(this);
            let length = 0;
            try { length = view || tag === "WebAssembly.Memory" ? this.buffer.byteLength : this.byteLength; } catch (e) {}
            // The memory underneath, numbered once: a WebAssembly.Memory by
            // itself, as its buffer is replaced when it grows.
            if (!holder.ids) { holder.ids = new WeakMap(); holder.nextID = 0; }
            let memory = this;
            try { memory = view ? this.buffer : this; } catch (e) {}
            let identity = holder.ids.get(memory);
            if (identity === undefined) { identity = ++holder.nextID; holder.ids.set(memory, identity); }
            return {slot, tag, length, offset: view ? this.byteOffset : 0, size: view ? this.byteLength : length, identity};
        }
        """

    /// The whole underlying buffer's bytes as a Uint8Array, for any kind.
    private static let bytesView = """
        const tag = Object.prototype.toString.call(this).slice(8, -1);
        let bytes;
        try {
            bytes = ArrayBuffer.isView(this) || tag === "WebAssembly.Memory" ? new Uint8Array(this.buffer) : new Uint8Array(this);
        } catch (e) { return {length: 0, detached: true, bytes: []}; }
        """

    private static let readFunction = """
        function(start, count) {
            \(bytesView)
            const from = Math.max(0, Math.min(start, bytes.length));
            const to = Math.min(bytes.length, from + count);
            const out = [];
            for (let i = from; i < to; i++) out.push(bytes[i]);
            return {length: bytes.length, start: from, bytes: out};
        }
        """

    private static let writeFunction = """
        function(address, values) {
            \(bytesView)
            for (let i = 0; i < values.length; i++) if (address + i < bytes.length) bytes[address + i] = values[i];
            return {length: bytes.length};
        }
        """
}

struct DeveloperMemoryInspectorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
