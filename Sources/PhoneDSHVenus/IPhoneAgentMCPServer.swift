// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation
import PhoneDSHAgentCore
import PhoneDSHLoopback

/// Inject the app's screen/HID executor; SDK tests do not touch a real phone.
@MainActor public protocol IPhoneAgentTaskExecuting: AnyObject, Sendable {
    func run(_ task: String) async throws -> IPhoneAgentResult
}

/// Keep UI-Venus behind the session's normal tool call/result journal. Voice and
/// ESP32 input still enter their fixed DSH session, including ordinary conversation.
public actor IPhoneAgentMCPServer: NativeMCPServing {
    private struct Receipt: Codable {
        let task: String
        var result: JSONValue?
    }
    private struct Active {
        let rpcID: JSONValue
        let key: String
        let task: Task<JSONValue, Never>
    }
    private let fallback: any NativeMCPServing
    private let executor: any IPhoneAgentTaskExecuting
    private let directory: URL
    private let executionTimeout: Duration
    private struct ExecutionTimeout: Error {}
    private var active: Active?

    public init(fallback: any NativeMCPServing, executor: any IPhoneAgentTaskExecuting, receiptDirectory: URL? = nil,
                executionTimeout: Duration = .seconds(600)) {
        self.fallback = fallback; self.executor = executor
        self.executionTimeout = executionTimeout
        directory = receiptDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iphone-agent-tool-receipts", isDirectory: true)
    }

    public func cancelPendingOperations() async {
        let pending = active?.task
        pending?.cancel()
        await fallback.cancelPendingOperations()
        _ = await pending?.value
    }

    public func handle(_ request: LoopbackRequest) async -> NativeMCPResponse {
        guard request.method == "POST", request.body.count <= 16384,
              let message = try? JSONValue.parse(request.body), message["jsonrpc"] == .string("2.0"),
              let method = message["method"]?.stringValue else { return await fallback.handle(request) }
        let params = message["params"]
        let key = request.headers.first { $0.key.lowercased() == "x-pdsh-idempotency-key" }?.value
        if method == "notifications/cancelled", message["id"] == nil,
           let active, params?["requestId"] == active.rpcID,
           key == nil || key == active.key {
            // The SDK allocates RPC IDs on its MCP connection. When the journal key
            // is carried on the notification it must also match the owning call.
            active.task.cancel()
            return NativeMCPResponse(status: 202)
        }
        if method == "initialize" || method == "tools/list" {
            var response = await fallback.handle(request)
            if var root = (try? JSONValue.parse(response.body))?.objectValue,
               var result = root["result"]?.objectValue {
                if method == "tools/list", let tools = result["tools"]?.arrayValue {
                    result["tools"] = .array(tools + [Self.descriptor])
                } else if method == "initialize" {
                    result["instructions"] = .string((result["instructions"]?.stringValue ?? "") + " " + Self.instructions)
                }
                root["result"] = .object(result)
                response.body = (try? JSONValue.object(root).encoded()) ?? Data()
            }
            return response
        }
        guard method == "tools/call", params?["name"] == .string("iphone_agent_run") else {
            return await fallback.handle(request)
        }
        guard let id = message["id"] else { return NativeMCPResponse(status: 202) }
        guard case .string = id else {
            if case .number = id { return await call(params: params, id: id, key: key) }
            return response(id: id, result: Self.failure("invalid_request"))
        }
        return await call(params: params, id: id, key: key)
    }

    private func call(params: JSONValue?, id: JSONValue, key: String?) async -> NativeMCPResponse {
        guard let args = params?["arguments"]?.objectValue, Set(args.keys) == ["task"],
              let text = args["task"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 8192 else { return response(id: id, result: Self.failure("invalid_arguments")) }
        guard let key, !key.isEmpty, key.utf8.count <= 256 else {
            return response(id: id, result: Self.failure("journal_key_required"))
        }
        do {
            let file = directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
            if FileManager.default.fileExists(atPath: file.path) {
                let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file))
                guard receipt.task == text else { return response(id: id, result: Self.failure("idempotency_conflict")) }
                if let result = receipt.result { return response(id: id, result: result) }
                if let active, active.key == key { return response(id: id, result: await active.task.value) }
                // A crash/interruption cannot authorize replay of physical phone actions.
                return response(id: id, result: Self.failure("outcome_unknown"))
            }
            guard active == nil else { return response(id: id, result: Self.failure("busy")) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).count < 4096 else {
                return response(id: id, result: Self.failure("store_full"))
            }
            try save(Receipt(task: text), to: file)
            let task = Task { await execute(text, file: file) }
            active = Active(rpcID: id, key: key, task: task)
            let result = await task.value
            active = nil
            return response(id: id, result: result)
        } catch { return response(id: id, result: Self.failure("receipt_storage_unavailable")) }
    }

    private func execute(_ text: String, file: URL) async -> JSONValue {
        let result: JSONValue
        do {
            try Task.checkCancellation()
            let executor = self.executor, timeout = executionTimeout
            let outcome = try await withThrowingTaskGroup(of: IPhoneAgentResult.self) { group in
                group.addTask { try await executor.run(text) }
                group.addTask { try await Task.sleep(for: timeout); throw ExecutionTimeout() }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            result = Self.result(.object([
                "answer": .string(outcome.answer), "finished": .bool(outcome.finished),
                "steps": .number(Double(outcome.steps.count)), "seconds": .number(outcome.seconds),
                "assessment": .string("model_report_not_independent_verification"),
            ]), isError: !outcome.finished)
        } catch is ExecutionTimeout { result = Self.failure("timeout_outcome_unknown") }
        catch is CancellationError { result = Self.failure("cancelled_outcome_unknown") }
        catch { result = Self.failure("iphone_agent_failed", detail: String(describing: error)) }
        do { try save(Receipt(task: text, result: result), to: file) }
        catch { return Self.failure("outcome_unknown") }
        return result
    }

    private func save(_ receipt: Receipt, to file: URL) throws {
        try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func response(id: JSONValue, result: JSONValue) -> NativeMCPResponse {
        NativeMCPResponse(body: (try? JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id, "result": result,
        ]).encoded()) ?? Data())
    }
    private static func result(_ value: JSONValue, isError: Bool) -> JSONValue {
        .object(["content": .array([.object([
            "type": .string("text"), "text": .string(String(decoding: (try? value.encoded()) ?? Data(), as: UTF8.self)),
        ])]), "isError": .bool(isError)])
    }
    private static func failure(_ code: String, detail: String? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["status": .string(code), "automatic_retry": .bool(false)]
        if let detail { value["detail"] = .string(String(detail.prefix(512))) }
        return result(.object(value), isError: true)
    }
    private static let volumeGuidance = "For current output-volume requests, default to the media/output slider in iOS Control Center. ‘Turn it up/down a little’ means one modest step (about 10 percentage points); a requested percentage is an approximate slider target; ‘mute’ means 0% on this slider, not Silent mode or ringer/alert volume. For an explicit ringer/alert or Silent mode request, clarify the control. Use the visible slider through the existing screen/HID path: inspect a fresh screenshot before acting and request another after the gesture. Claim completion only if the new screenshot visibly confirms the target. If the phone is locked, the slider is unavailable, or the result is unclear, ask the user or report the limitation. Never use private volume APIs or replay an uncertain adjustment."
    private static let completionGuidance = "After a task, report the answer or concrete blocker in one short sentence. Omit step counts, durations, finished values, model self-assessment, and UI navigation details."
    private static let instructions = "For phone UI tasks, use iphone_agent_run on this iPhone unless the user explicitly targets Android. Resolve references using only this conversation, then provide a self-contained task. UI-Venus uses the local board screen/HID; its result is a model assessment. Do not claim success when finished is false. Describe what to achieve or report, not navigation chores: for a lookup write e.g. 「打开设置里的电池页并报告电量」 and do not add 'then return to the home page' steps (the agent answers as soon as it sees the information). If the result answer starts with 卡住了, tell the user what happened instead of starting the same task again. Only one phone task runs at a time, so busy means wait, not cancel the other task. Never automatically replay an uncertain action; the journal key protects retries. Keep conversation and task results in this DSH session. " + completionGuidance + " " + volumeGuidance
    public static let descriptor: JSONValue = .object([
        "name": .string("iphone_agent_run"), "description": .string(instructions),
        "inputSchema": .object([
            "type": .string("object"), "properties": .object([
                "task": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(8192)]),
            ]), "required": .array([.string("task")]), "additionalProperties": .bool(false),
        ]),
        "annotations": .object(["readOnlyHint": .bool(false), "idempotentHint": .bool(false)]),
    ])
}
