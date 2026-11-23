import SwiftUI

/// Chrome's Memory inspector drawer tool: a tab per inspected buffer, an
/// address bar (history back and forward, go to address, previous and next
/// page), the hex view (addresses, bytes, ASCII) with the selected byte and
/// the inspected view's own range highlighted, and the value pane reading
/// the bytes at the selection as integers, floats and pointers in either
/// byte order. Typing two hex digits over the selected byte writes it.
struct DeveloperMemoryInspectorView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var memory: DeveloperMemoryInspectorModel
    @State private var addressText = ""
    @State private var addressInvalid = false
    /// The first hex digit typed over the selected byte, awaiting the second.
    @State private var pendingDigit: Character?
    @FocusState private var gridFocused: Bool

    private static let addressWidth: CGFloat = 86
    private static let hexCell: CGFloat = 20
    private static let asciiCell: CGFloat = 8
    private static let valuePaneWidth: CGFloat = 270

    init(session: DeveloperToolsSession) {
        self.session = session
        memory = DeveloperMemoryInspectorModel.model(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            if memory.buffers.isEmpty {
                VStack(spacing: 6) {
                    if let problem = memory.problem { Text(problem).foregroundStyle(.secondary) }
                    Text("No open inspections").fontWeight(.semibold)
                    Text("Right-click an ArrayBuffer, TypedArray, DataView or WebAssembly.Memory in the Console or in the Scope pane while paused, and choose Reveal in Memory inspector.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabs
                Divider()
                if let buffer = memory.selected {
                    toolbar(buffer)
                    Divider()
                    if let problem = buffer.problem ?? memory.problem {
                        Text(problem).foregroundStyle(.secondary)
                            .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DeveloperToolsStyle.raised)
                        Divider()
                    }
                    HStack(spacing: 0) {
                        grid(buffer).frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        values(buffer).frame(width: Self.valuePaneWidth)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .onAppear {
            memory.start()
            if let address = memory.selected?.selected { addressText = DeveloperMemoryAddress.format(address) }
        }
        .onDisappear { memory.stop() }
        .onChange(of: memory.selected?.selected) { _, address in
            if let address { addressText = DeveloperMemoryAddress.format(address) }
            pendingDigit = nil
        }
        .accessibilityIdentifier("developer-memory-inspector")
    }

    // MARK: Tabs and toolbar

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                ForEach(memory.buffers) { buffer in
                    let selected = memory.selected?.id == buffer.id
                    HStack(spacing: 4) {
                        Button { memory.selectedID = buffer.id } label: {
                            Text(buffer.title)
                        }
                        .buttonStyle(.plain)
                        Button { memory.close(buffer.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Close " + buffer.title)
                    }
                    .developerTab(selected: selected)
                    .help(buffer.className + ", \(buffer.length) bytes")
                }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
        }
        .scrollIndicators(.never)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private func toolbar(_ buffer: DeveloperMemoryInspectorModel.Buffer) -> some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            DeveloperPanelIcon(symbol: "chevron.backward", title: "Go back in address history") { memory.back() }
                .disabled(!buffer.history.canGoBack)
            DeveloperPanelIcon(symbol: "chevron.forward", title: "Go forward in address history") { memory.forward() }
                .disabled(!buffer.history.canGoForward)
            TextField("Enter address", text: $addressText)
                .developerToolsField()
                .font(DeveloperToolsStyle.code)
                .frame(width: 130)
                .overlay {
                    if addressInvalid {
                        RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius).stroke(Color.red, lineWidth: 1)
                    }
                }
                .onSubmit {
                    let parsed = DeveloperMemoryAddress.parse(addressText)
                    addressInvalid = !(parsed.map { memory.go(to: $0) } ?? false)
                }
                .onChange(of: addressText) { _, _ in addressInvalid = false }
                .help("An address in hex (0x1A) or decimal (26), from 0 to \(DeveloperMemoryAddress.format(max(0, buffer.length - 1)))")
            DeveloperPanelIcon(symbol: "chevron.left.2", title: "Previous page") { memory.step(pages: -1) }
                .disabled(buffer.pageStart == 0)
            DeveloperPanelIcon(symbol: "chevron.right.2", title: "Next page") { memory.step(pages: 1) }
                .disabled(buffer.pageStart + memory.layout.pageSize >= buffer.length)
            DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Refresh") { memory.refresh() }
            Spacer()
            Text("\(buffer.className) · \(buffer.length.formatted()) bytes"
                 + (buffer.kind == .typedArray || buffer.kind == .dataView
                    ? " · view at \(DeveloperMemoryAddress.format(buffer.regionStart)), \(buffer.regionLength) bytes" : ""))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    // MARK: Hex view

    private func grid(_ buffer: DeveloperMemoryInspectorModel.Buffer) -> some View {
        let layout = memory.layout
        let starts = layout.rowStarts(page: buffer.pageStart, length: buffer.length)
        return GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(starts, id: \.self) { start in
                        row(buffer, start: start, perRow: layout.bytesPerRow)
                    }
                    if buffer.length == 0 {
                        Text("The buffer is empty.").foregroundStyle(.secondary).padding(DeveloperToolsStyle.gutter)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { reflow(proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in reflow(width) }
        }
        .font(DeveloperToolsStyle.code)
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in key(press, buffer) }
    }

    private func reflow(_ width: CGFloat) {
        let count = DeveloperMemoryLayout.bytesPerRow(fitting: Double(width), byteWidth: Double(Self.hexCell + Self.asciiCell),
                                                      fixed: Double(Self.addressWidth + 24))
        memory.setBytesPerRow(count)
    }

    private func row(_ buffer: DeveloperMemoryInspectorModel.Buffer, start: Int, perRow: Int) -> some View {
        let end = min(buffer.length, start + perRow)
        return HStack(spacing: 0) {
            Text(DeveloperMemoryAddress.digits(start, length: buffer.length))
                .foregroundStyle(.secondary)
                .frame(width: Self.addressWidth, alignment: .leading)
                .padding(.leading, DeveloperToolsStyle.gutter)
            ForEach(start..<start + perRow, id: \.self) { address in
                cell(buffer, address: address, inRange: address < end, ascii: false)
                    .padding(.leading, address > start && (address - start) % 8 == 0 ? 6 : 0)
            }
            Color.clear.frame(width: 12)
            ForEach(start..<start + perRow, id: \.self) { address in
                cell(buffer, address: address, inRange: address < end, ascii: true)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 17)
    }

    private func cell(_ buffer: DeveloperMemoryInspectorModel.Buffer, address: Int, inRange: Bool, ascii: Bool) -> some View {
        let offset = address - buffer.pageStart
        let byte: UInt8? = inRange && offset >= 0 && offset < buffer.bytes.count ? buffer.bytes[offset] : nil
        let selected = address == buffer.selected && inRange
        let inView = (buffer.kind == .typedArray || buffer.kind == .dataView)
            && address >= buffer.regionStart && address < buffer.regionStart + buffer.regionLength
        let text: String
        if let byte {
            text = ascii ? String(DeveloperMemoryBytes.ascii(byte))
                : (selected && pendingDigit != nil ? String(pendingDigit!) + "_" : DeveloperMemoryBytes.hex(byte))
        } else {
            text = inRange ? (ascii ? " " : "··") : (ascii ? " " : "  ")
        }
        return Text(text)
            .foregroundStyle(byte == nil ? Color.secondary : (selected ? Color.white : Palette.ink))
            .frame(width: ascii ? Self.asciiCell : Self.hexCell, height: 16)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 2).fill(DeveloperToolsStyle.tint)
                } else if inView {
                    Rectangle().fill(DeveloperToolsStyle.tint.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard inRange else { return }
                memory.select(address)
                gridFocused = true
            }
    }

    /// Arrow keys move the selection (across pages too); two hex digits
    /// write the byte.
    private func key(_ press: KeyPress, _ buffer: DeveloperMemoryInspectorModel.Buffer) -> KeyPress.Result {
        let perRow = memory.layout.bytesPerRow
        let move: Int? = switch press.key {
        case .leftArrow: -1
        case .rightArrow: 1
        case .upArrow: -perRow
        case .downArrow: perRow
        case .pageUp: -memory.layout.pageSize
        case .pageDown: memory.layout.pageSize
        default: nil
        }
        if let move {
            let target = buffer.selected + move
            guard target >= 0, target < buffer.length else { return .handled }
            if memory.layout.pageStart(target) == buffer.pageStart { memory.select(target) } else { memory.go(to: target) }
            return .handled
        }
        if press.key == .escape, pendingDigit != nil {
            pendingDigit = nil
            return .handled
        }
        guard let character = press.characters.first, press.characters.count == 1, character.isHexDigit,
              press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        if let first = pendingDigit {
            pendingDigit = nil
            if let value = DeveloperMemoryBytes.parse(String([first, character])) {
                memory.write(buffer.selected, value: value)
                let next = buffer.selected + 1
                if next < buffer.length {
                    if memory.layout.pageStart(next) == buffer.pageStart { memory.select(next) } else { memory.go(to: next) }
                }
            }
        } else {
            pendingDigit = Character(character.uppercased())
        }
        return .handled
    }

    // MARK: Value pane

    private func values(_ buffer: DeveloperMemoryInspectorModel.Buffer) -> some View {
        let offset = buffer.selected - buffer.pageStart
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Picker("Endianness", selection: $memory.endianness) {
                    ForEach(DeveloperMemoryValue.Endianness.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Menu {
                    ForEach(DeveloperMemoryValue.Format.allCases) { format in
                        Toggle(format.rawValue, isOn: Binding(
                            get: { memory.formats.contains(format) },
                            set: { on in
                                if on { memory.formats = DeveloperMemoryValue.Format.allCases.filter { memory.formats.contains($0) || $0 == format } }
                                else { memory.formats.removeAll { $0 == format } }
                            }))
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Value types shown")
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            Divider()
            Text("At " + DeveloperMemoryAddress.format(buffer.selected, length: buffer.length))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .padding(.vertical, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(memory.formats) { format in
                        valueRow(format, buffer: buffer, offset: offset)
                    }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .padding(.bottom, DeveloperToolsStyle.gutter)
            }
        }
        .background(DeveloperToolsStyle.surface)
    }

    private func valueRow(_ format: DeveloperMemoryValue.Format, buffer: DeveloperMemoryInspectorModel.Buffer, offset: Int) -> some View {
        let text = DeveloperMemoryValue.text(format, bytes: buffer.bytes, at: offset, endian: memory.endianness,
                                             mode: memory.integerMode)
        let pointer = DeveloperMemoryValue.pointerTarget(format, bytes: buffer.bytes, at: offset, endian: memory.endianness,
                                                         length: buffer.length)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(format.rawValue).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            if format.isInteger {
                Menu(memory.integerMode.rawValue) {
                    ForEach(DeveloperMemoryValue.IntegerMode.allCases) { mode in
                        Button(mode.rawValue) { memory.integerMode = mode }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Integer display")
            }
            Text(text ?? "N/A")
                .font(DeveloperToolsStyle.code)
                .foregroundStyle(text == nil ? .secondary : Palette.ink)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if format.isPointer {
                DeveloperPanelIcon(symbol: "arrow.turn.down.right", title: "Jump to address", size: 16) {
                    if let pointer { memory.go(to: pointer) }
                }
                .disabled(pointer == nil)
            }
        }
    }
}
