import XCTest
@testable import Search

/// The WebAudio tool's graph: nodes and connections as the page's
/// connect and disconnect calls change them, and where the graph view
/// puts each node.
@MainActor
final class DeveloperWebAudioTests: XCTestCase {
    private func graph() -> DeveloperWebAudioGraph {
        var graph = DeveloperWebAudioGraph()
        graph.add(DeveloperWebAudioNode(id: "osc", type: "OscillatorNode", inputs: 0,
                                        params: [DeveloperWebAudioParam(name: "frequency", value: 440, rate: "a-rate")]))
        graph.add(DeveloperWebAudioNode(id: "lfo", type: "OscillatorNode", inputs: 0))
        graph.add(DeveloperWebAudioNode(id: "gain", type: "GainNode",
                                        params: [DeveloperWebAudioParam(name: "gain", value: 1, rate: "a-rate")]))
        graph.add(DeveloperWebAudioNode(id: "out", type: "AudioDestinationNode", outputs: 0))
        return graph
    }

    func testConnectionsAreAddedOnceAndOnlyBetweenKnownNodes() {
        var graph = graph()
        graph.connect(DeveloperWebAudioEdge(source: "osc", destination: "gain"))
        graph.connect(DeveloperWebAudioEdge(source: "osc", destination: "gain"))
        graph.connect(DeveloperWebAudioEdge(source: "gain", destination: "out"))
        graph.connect(DeveloperWebAudioEdge(source: "lfo", destination: "gain", param: "gain"))
        graph.connect(DeveloperWebAudioEdge(source: "lfo", destination: "osc", param: "frequency"))
        // Not in the graph, or no such param: left out.
        graph.connect(DeveloperWebAudioEdge(source: "ghost", destination: "out"))
        graph.connect(DeveloperWebAudioEdge(source: "lfo", destination: "gain", param: "detune"))
        XCTAssertEqual(graph.edges.count, 4)
        XCTAssertEqual(graph.nodes.count, 4)

        // The same node described again replaces it rather than adding one.
        graph.add(DeveloperWebAudioNode(id: "gain", type: "GainNode", channelCount: 1,
                                        params: [DeveloperWebAudioParam(name: "gain", value: 0.5, rate: "a-rate")]))
        XCTAssertEqual(graph.nodes.count, 4)
        XCTAssertEqual(graph.node("gain")?.channelCount, 1)
    }

    func testDisconnectTakesTheConnectionsEachFormNames() {
        var graph = graph()
        graph.connect(DeveloperWebAudioEdge(source: "osc", destination: "gain"))
        graph.connect(DeveloperWebAudioEdge(source: "osc", destination: "out"))
        graph.connect(DeveloperWebAudioEdge(source: "lfo", destination: "gain", param: "gain"))
        graph.connect(DeveloperWebAudioEdge(source: "lfo", destination: "gain"))
        graph.connect(DeveloperWebAudioEdge(source: "gain", destination: "out"))

        // disconnect(param): only the connection to the param.
        graph.disconnect(source: "lfo", destination: "gain", param: "gain")
        XCTAssertFalse(graph.edges.contains { $0.param != nil })
        XCTAssertTrue(graph.edges.contains(DeveloperWebAudioEdge(source: "lfo", destination: "gain")))

        // disconnect(node): only the connections to that node.
        graph.disconnect(source: "osc", destination: "out")
        XCTAssertEqual(graph.edges.filter { $0.source == "osc" }.map(\.destination), ["gain"])

        // disconnect(node, output) with another output: nothing.
        graph.disconnect(source: "osc", output: 1, destination: "gain")
        XCTAssertEqual(graph.edges.filter { $0.source == "osc" }.count, 1)

        // disconnect(): everything from the node.
        graph.disconnect(source: "osc")
        XCTAssertFalse(graph.edges.contains { $0.source == "osc" })
        XCTAssertEqual(graph.edges.count, 2)

        // A node the page let go of takes its connections with it.
        graph.remove("gain")
        XCTAssertEqual(graph.edges, [])
        XCTAssertNil(graph.node("gain"))
    }

    func testColumnsRunFromSourcesToTheDestinationThroughFeedback() {
        var graph = graph()
        graph.add(DeveloperWebAudioNode(id: "delay", type: "DelayNode"))
        graph.connect(DeveloperWebAudioEdge(source: "osc", destination: "gain"))
        graph.connect(DeveloperWebAudioEdge(source: "gain", destination: "delay"))
        graph.connect(DeveloperWebAudioEdge(source: "delay", destination: "gain"))
        graph.connect(DeveloperWebAudioEdge(source: "gain", destination: "out"))
        let columns = graph.columns()
        XCTAssertEqual(columns.first?.map(\.id), ["osc", "lfo"])
        XCTAssertEqual(columns.flatMap { $0 }.count, 5)
        let layout = DeveloperWebAudioLayout(graph)
        XCTAssertEqual(layout.frames.count, 5)
        let osc = try! XCTUnwrap(layout.frames["osc"]), gain = try! XCTUnwrap(layout.frames["gain"])
        let out = try! XCTUnwrap(layout.frames["out"])
        XCTAssertLessThan(osc.maxX, gain.minX)
        XCTAssertLessThan(gain.maxX, out.minX)
        XCTAssertGreaterThan(layout.size.width, 0)
    }

    func testPropertiesFollowChrome() {
        var context = DeveloperWebAudioContext(id: "f-c1", type: "realtime", state: "running", sampleRate: 48_000,
                                               currentTime: 1.5, baseLatency: 0.01, outputLatency: nil,
                                               maxChannelCount: 2)
        context.graph = graph()
        let rows = DeveloperWebAudioView.rows(for: context)
        XCTAssertEqual(rows.first { $0.name == "Sample rate" }?.value, "48000 Hz")
        XCTAssertEqual(rows.first { $0.name == "State" }?.value, "running")
        XCTAssertEqual(rows.first { $0.name == "Nodes" }?.value, "4")
        context.type = "offline"
        XCTAssertNil(DeveloperWebAudioView.rows(for: context).first { $0.name == "Base latency" })
    }
}
