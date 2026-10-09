@testable import ClipShelf
import XCTest

@MainActor
final class MCPBridgeTests: XCTestCase {
    func testNodeStdioBridgeInitializesListsToolsAndKeepsStdoutProtocolOnly() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        let url = try await server.start()
        defer { server.stop() }
        let issued = try fixture.authorize([.read])
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "bridge-test", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        ]
        let input = try messages.reduce(into: Data()) { result, message in
            result.append(try JSONSerialization.data(withJSONObject: message))
            result.append(10)
        }
        let result = try await runBridge(input: input, url: url.absoluteString, token: issued.token)
        if result.status == 127 { throw XCTSkip("Node is not installed in this test environment") }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let responses = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(responses.compactMap { $0?["id"] as? Int }, [1, 2])
        let listResult = responses.last??["result"] as? [String: Any]
        XCTAssertEqual((listResult?["tools"] as? [[String: Any]])?.count, 3)
        XCTAssertFalse(result.stdout.contains(issued.token))
        XCTAssertFalse(result.stderr.contains(issued.token))
    }

    func testNodeBridgeRejectsRemoteURLWithoutLeakingToken() async throws {
        let syntheticToken = "cs_" + String(repeating: "a", count: 43)
        let result = try await runBridge(input: Data(), url: "http://example.com:1234/mcp", token: syntheticToken)
        if result.status == 127 { throw XCTSkip("Node is not installed in this test environment") }
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertFalse(result.stderr.contains(syntheticToken))
        XCTAssertFalse(result.stderr.contains("example.com"))
    }

    func testNodeOAuthBridgeUsesActualPKCEHTTPAndRejectsBadCallbackState() async throws {
        let fixture = try MCPTestFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(router: fixture.router, authorizationStore: fixture.auth)
        var prompts = 0
        server.onAuthorizationRequest = { request in
            prompts += 1
            XCTAssertEqual(request.clientName, "ClipShelf stdio bridge")
            return MCPOAuthApproval(permissions: [.read], scope: .init(includeHistory: true))
        }
        let url = try await server.start()
        defer { server.stop() }
        let code = #"""
        import http from 'node:http';
        import assert from 'node:assert/strict';
        import { pathToFileURL } from 'node:url';
        const { createOAuthCredentials, createBridge } = await import(pathToFileURL(process.env.CLIPSHELF_BRIDGE_PATH));
        const get = (url) => new Promise((resolve, reject) => {
          const request = http.get(url, { agent: false }, response => {
            response.resume(); response.on('end', () => resolve(response));
          }); request.on('error', reject);
        });
        const getToken = await createOAuthCredentials({ url: process.env.CLIPSHELF_MCP_URL,
          openAuthorizationURL: async value => {
            const auth = new URL(value);
            const badCallback = new URL(auth.searchParams.get('redirect_uri'));
            badCallback.search = new URLSearchParams({ state: 'é'.repeat(43), code: 'csa_' + 'a'.repeat(43) });
            assert.equal((await get(badCallback)).statusCode, 400);
            const response = await get(auth);
            assert.equal(response.statusCode, 302);
            assert.equal((await get(response.headers.location)).statusCode, 200);
          }
        });
        const bridge = createBridge({ url: process.env.CLIPSHELF_MCP_URL, getToken });
        const initialized = await bridge.forward({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
          protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'oauth-bridge-test', version: '1' }
        }});
        assert.equal(initialized.result.protocolVersion, '2025-11-25');
        await bridge.forward({ jsonrpc: '2.0', method: 'notifications/initialized' });
        const listed = await bridge.forward({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
        assert.equal(listed.result.tools.length, 3);
        await bridge.close();
        process.stdout.write('oauth-pkce-and-tools-ok\n');
        """#
        let result = try await runBridge(input: Data(), url: url.absoluteString, token: "", nodeCode: code)
        if result.status == 127 { throw XCTSkip("Node is not installed in this test environment") }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "oauth-pkce-and-tools-ok\n")
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(fixture.auth.clients.count, 1)
    }

    private func runBridge(input: Data, url: String, token: String, nodeCode: String? = nil) async throws -> (status: Int32, stdout: String, stderr: String) {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/mcp-bridge.mjs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = nodeCode.map { ["node", "--input-type=module", "--eval", $0] } ?? ["node", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CLIPSHELF_MCP_URL"] = url
        environment["CLIPSHELF_MCP_TOKEN"] = token
        environment["CLIPSHELF_BRIDGE_PATH"] = script.path
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let stdout = Task.detached { outputPipe.fileHandleForReading.readDataToEndOfFile() }
        let stderr = Task.detached { errorPipe.fileHandleForReading.readDataToEndOfFile() }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if process.isRunning { process.terminate() }
        }
        defer { timeout.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do {
                try process.run()
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                process.terminationHandler = nil
                if process.isRunning { process.terminate() }
                try? inputPipe.fileHandleForWriting.close()
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
        return (status, String(decoding: await stdout.value, as: UTF8.self), String(decoding: await stderr.value, as: UTF8.self))
    }
}
