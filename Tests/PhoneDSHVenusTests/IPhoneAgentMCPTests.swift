// SPDX-License-Identifier: MIT
import XCTest
import Foundation
import PhoneDSHAgentCore
import PhoneDSHLoopback
@testable import PhoneDSHVenus

private actor PhoneToolFallback: NativeMCPServing {
    func handle(_ request: LoopbackRequest) async -> NativeMCPResponse {
        let rpc = try! JSONValue.parse(request.body)
        let result: JSONValue = rpc["method"] == .string("tools/list")
            ? .object(["tools": .array([.object(["name": .string("android_tap")])])])
            : .object(["instructions": .string("existing tools"), "forwarded": .bool(true)])
        return NativeMCPResponse(body: try! JSONValue.object([
            "jsonrpc": .string("2.0"), "id": rpc["id"] ?? .null, "result": result,
        ]).encoded())
    }
}

@MainActor private final class PhoneToolExecutor: IPhoneAgentTaskExecuting {
    var tasks: [String] = []
    var blocked = false
    var finished = true
    func run(_ task: String) async throws -> IPhoneAgentResult {
        tasks.append(task)
        if blocked { try await Task.sleep(for: .seconds(60)) }
        return IPhoneAgentResult(answer: "result for \(task)", finished: finished, steps: [], seconds: 1)
    }
}

private struct IPhoneAgentVolumeFixture: Decodable {
    struct InvalidArguments: Decodable {
        let name: String
        let arguments: [String: String]?
        let taskUtf8Bytes: Int?
        let expectedStatus: String
    }
    let tool: String
    let instructions: String
    let completionGuidance: String
    let validTasks: [String]
    let invalidArguments: [InvalidArguments]
}

@MainActor final class IPhoneAgentMCPTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func server(_ executor: PhoneToolExecutor) -> IPhoneAgentMCPServer {
        IPhoneAgentMCPServer(fallback: PhoneToolFallback(), executor: executor, receiptDirectory: directory)
    }
    private func rpc(_ method: String = "tools/call", id: Int? = 1, key: String? = "session-a-call-1",
                     args: [String: JSONValue] = ["task": .string("open Settings")],
                     name: String = "iphone_agent_run", params: JSONValue? = nil) throws -> LoopbackRequest {
        var value: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method),
            "params": params ?? .object(["name": .string(name), "arguments": .object(args)])]
        if let id { value["id"] = .number(Double(id)) }
        return LoopbackRequest(method: "POST", path: "/mcp/native",
            headers: key.map { ["X-PDSH-Idempotency-Key": $0] } ?? [:], body: try JSONValue.object(value).encoded())
    }
    private func root(_ response: NativeMCPResponse) throws -> JSONValue { try JSONValue.parse(response.body) }
    private func payload(_ response: NativeMCPResponse) throws -> JSONValue {
        let text = try XCTUnwrap(try root(response)["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        return try JSONValue.parse(Data(text.utf8))
    }
    private func volumeFixture() throws -> IPhoneAgentVolumeFixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("spec/v1/golden/native-mcp/iphone-agent-volume-policy.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(IPhoneAgentVolumeFixture.self, from: Data(contentsOf: url))
    }
    private func started(_ executor: PhoneToolExecutor) async throws {
        for _ in 0..<1000 {
            if !executor.tasks.isEmpty { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("executor did not start")
    }

    func testCatalogInstructionsAndExistingToolsRemainAvailable() async throws {
        let executor = PhoneToolExecutor(), service = server(executor)
        let fixture = try volumeFixture()
        let list = try root(await service.handle(rpc("tools/list")))
        XCTAssertEqual(list["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue },
                       ["android_tap", fixture.tool])
        let descriptor = try XCTUnwrap(list["result"]?["tools"]?.arrayValue?.last)
        XCTAssertTrue(descriptor["description"]?.stringValue?.contains(fixture.instructions) == true)
        XCTAssertTrue(descriptor["description"]?.stringValue?.contains(fixture.completionGuidance) == true)
        let initResult = try root(await service.handle(rpc("initialize")))
        let instructions = initResult["result"]?["instructions"]?.stringValue ?? ""
        XCTAssertTrue(instructions.contains("this DSH session"))
        XCTAssertTrue(instructions.contains(fixture.instructions))
        XCTAssertTrue(instructions.contains(fixture.completionGuidance))
        let other = try root(await service.handle(rpc(name: "android_tap")))
        XCTAssertEqual(other["result"]?["forwarded"], .bool(true))
        XCTAssertTrue(executor.tasks.isEmpty)
    }

    func testSharedVolumeTasksReachTheRealExecutor() async throws {
        let fixture = try volumeFixture()
        let executor = PhoneToolExecutor()
        let service = server(executor)
        for (index, task) in fixture.validTasks.enumerated() {
            let response = await service.handle(try rpc(id: index + 1, key: "volume-example-\(index)",
                                                        args: ["task": .string(task)], name: fixture.tool))
            XCTAssertEqual(try payload(response)["finished"], .bool(true))
        }
        XCTAssertEqual(executor.tasks, fixture.validTasks)
    }

    func testSharedInvalidVolumeArgumentsAreRejectedBeforeExecution() async throws {
        let fixture = try volumeFixture()
        let executor = PhoneToolExecutor()
        let service = server(executor)
        for (index, item) in fixture.invalidArguments.enumerated() {
            var args = item.arguments?.mapValues(JSONValue.string) ?? [:]
            if let count = item.taskUtf8Bytes { args["task"] = .string(String(repeating: "x", count: count)) }
            let response = await service.handle(try rpc(id: index + 1, key: "volume-invalid-\(index)",
                                                        args: args, name: fixture.tool))
            XCTAssertEqual(try payload(response)["status"], .string(item.expectedStatus), item.name)
        }
        XCTAssertTrue(executor.tasks.isEmpty)
    }

    func testCompletedCallIsDurableAndRetryUsesCurrentRPCID() async throws {
        let executor = PhoneToolExecutor(), service = server(executor)
        let first = await service.handle(try rpc())
        XCTAssertEqual(try payload(first)["answer"], .string("result for open Settings"))
        let reopened = server(executor)
        let retry = await reopened.handle(try rpc(id: 99))
        XCTAssertEqual(try root(retry)["id"], .number(99))
        XCTAssertEqual(try payload(retry), try payload(first))
        XCTAssertEqual(executor.tasks.count, 1)
        let conflict = await reopened.handle(try rpc(args: ["task": .string("send money")]))
        XCTAssertEqual(try payload(conflict)["status"], .string("idempotency_conflict"))
        XCTAssertEqual(executor.tasks.count, 1)
    }

    func testStrictArgumentsAndJournalKeyRequiredBeforeExecution() async throws {
        let executor = PhoneToolExecutor(), service = server(executor)
        for args: [String: JSONValue] in [[:], ["task": .string(" ")],
            ["task": .string(String(repeating: "x", count: 8193))],
            ["task": .string("open Settings"), "session_id": .string("other-device")]] {
            let response = await service.handle(try rpc(args: args))
            XCTAssertEqual(try payload(response)["status"], .string("invalid_arguments"))
        }
        let noKey = await service.handle(try rpc(key: nil))
        XCTAssertEqual(try payload(noKey)["status"], .string("journal_key_required"))
        XCTAssertTrue(executor.tasks.isEmpty)
    }

    func testUnfinishedTaskIsReportedAsAnError() async throws {
        let executor = PhoneToolExecutor(); executor.finished = false
        let response = await server(executor).handle(try rpc())
        XCTAssertEqual(try root(response)["result"]?["isError"], .bool(true))
        XCTAssertEqual(try payload(response)["finished"], .bool(false))
    }

    func testTimeoutCancelsExecutorAndPersistsUncertainResultWithoutReplay() async throws {
        let executor = PhoneToolExecutor(); executor.blocked = true
        let service = IPhoneAgentMCPServer(fallback: PhoneToolFallback(), executor: executor,
            receiptDirectory: directory, executionTimeout: .milliseconds(20))
        let response = await service.handle(try rpc())
        XCTAssertEqual(try payload(response)["status"], .string("timeout_outcome_unknown"))
        let retry = await server(executor).handle(try rpc(id: 4))
        XCTAssertEqual(try payload(retry), try payload(response))
        XCTAssertEqual(executor.tasks.count, 1)
    }

    func testOtherDeviceGetsBusyWithoutReceivingActiveTaskOrResult() async throws {
        let executor = PhoneToolExecutor(); executor.blocked = true
        let service = server(executor)
        let first = Task { await service.handle(try rpc()) }
        try await started(executor)
        let busy = await service.handle(try rpc(id: 2, key: "session-b-call-1", args: ["task": .string("open Photos")]))
        XCTAssertEqual(try payload(busy)["status"], .string("busy"))
        XCTAssertFalse(String(decoding: busy.body, as: UTF8.self).contains("Settings"))
        await service.cancelPendingOperations()
        _ = try await first.value
        executor.blocked = false
        let next = await service.handle(try rpc(id: 2, key: "session-b-call-1", args: ["task": .string("open Photos")]))
        XCTAssertEqual(try payload(next)["answer"], .string("result for open Photos"))
        XCTAssertEqual(executor.tasks, ["open Settings", "open Photos"])
    }

    func testPendingReceiptAfterRestartIsNeverReplayed() async throws {
        let executor = PhoneToolExecutor(); executor.blocked = true
        let service = server(executor)
        let first = Task { await service.handle(try rpc()) }
        try await started(executor)
        let retry = await server(executor).handle(try rpc(id: 3))
        XCTAssertEqual(try payload(retry)["status"], .string("outcome_unknown"))
        XCTAssertEqual(executor.tasks.count, 1)
        await service.cancelPendingOperations()
        _ = try await first.value
    }

    func testDuplicateJoinsAndOnlyOwningCancellationStopsTask() async throws {
        let executor = PhoneToolExecutor(); executor.blocked = true
        let service = server(executor)
        let first = Task { await service.handle(try rpc()) }
        try await started(executor)
        let duplicate = Task { await service.handle(try rpc(id: 9)) }
        _ = await service.handle(try rpc("notifications/cancelled", id: nil, key: "session-b-call-1",
            params: .object(["requestId": .number(1)])))
        _ = await service.handle(try rpc("notifications/cancelled", id: nil,
            params: .object(["requestId": .number(2)])))
        let busy = await service.handle(try rpc(id: 2, key: "session-b-call-1"))
        XCTAssertEqual(try payload(busy)["status"], .string("busy"))
        _ = await service.handle(try rpc("notifications/cancelled", id: nil,
            params: .object(["requestId": .number(1)])))
        let cancelled = try await first.value, joined = try await duplicate.value
        XCTAssertEqual(try payload(cancelled)["status"], .string("cancelled_outcome_unknown"))
        XCTAssertEqual(try payload(joined), try payload(cancelled))
        XCTAssertEqual(executor.tasks.count, 1)
        executor.blocked = false
        let successor = await service.handle(try rpc(id: 2, key: "session-b-call-1"))
        XCTAssertEqual(try payload(successor)["finished"], .bool(true))
    }
}
