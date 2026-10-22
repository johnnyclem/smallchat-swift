import ArgumentParser
import Foundation
import SmallChat

/// The opt-in judge options `resolve`, `explain` and `repl` share, the same
/// as the TypeScript CLI's: a shortlist judge for near-ties, a running
/// stenographer whose tombstones and transcript it reads with, and a
/// decision log. Nothing here changes what runs: a judge only chooses
/// among candidates the policy already allows.
struct JudgeOptions: ParsableArguments {
    @Option(help: "Shortlist judge for near-ties: d1 (local llama-server, SMALLCHAT_D1_URL), jev (TypeSafe, TYPESAFE_API_KEY) or a System One endpoint URL (default: SMALLCHAT_JUDGE, else none)")
    var judge: String?

    @Option(name: .customLong("judge-context"), help: "A running stenographer's REST root (e.g. http://127.0.0.1:8787): its tombstones and transcript are offered to the judge (default: SMALLCHAT_JUDGE_CONTEXT)")
    var judgeContext: String?

    @Option(name: .customLong("judge-context-token-file"), help: "File holding stenographer's REST bearer token (default: STENOGRAPHER_REST_TOKEN, else ./rest-token when present)")
    var judgeContextTokenFile: String?

    @Option(name: .customLong("decision-log"), help: "Append every resolution to this hash-chained JSONL decision log (smallchat replay reads it)")
    var decisionLog: String?

    /// The runtime options these flags ask for, with one line per applied option on stderr.
    func runtimeOptions(env: [String: String] = ProcessInfo.processInfo.environment) throws -> RuntimeOptions {
        var options = RuntimeOptions()
        do {
            options.judge = try judgeFromSpec(judge, env: env)
        } catch let error as SystemOneJudgeError {
            throw ValidationError(error.message)
        }
        if let judge = options.judge {
            note("judge: \(judge.name) (\(judge.model))")
            if let provider = try judgeContextProvider(env: env) {
                options.judgeContext = provider
                note("judge context: \(provider.client.baseURL.absoluteString)\(provider.client.authenticated ? " (bearer token)" : "")")
            }
        } else if judgeContext != nil {
            note("--judge-context is ignored without --judge")
        }
        if let path = decisionLog {
            do {
                options.decisionLog = try DecisionLog(path: path)
            } catch {
                throw ValidationError("--decision-log: \(error)")
            }
            note("decision log: \(path)")
        }
        return options
    }

    /// The stenographer the judge reads with, or nil when none is named.
    func judgeContextProvider(env: [String: String]) throws -> StenographerJudgeContext? {
        guard let raw = judgeContext?.trimmingCharacters(in: .whitespaces).nonEmpty ?? env["SMALLCHAT_JUDGE_CONTEXT"]?.trimmingCharacters(in: .whitespaces).nonEmpty else { return nil }
        guard let url = URL(string: raw) else { throw ValidationError("--judge-context: \"\(raw)\" is not a URL") }
        var token = env["STENOGRAPHER_REST_TOKEN"]?.trimmingCharacters(in: .whitespaces).nonEmpty
        let file = judgeContextTokenFile ?? (token == nil ? "./rest-token" : nil)
        if let file {
            if let contents = try? String(contentsOfFile: file, encoding: .utf8) {
                token = contents.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            } else if judgeContextTokenFile != nil {
                throw ValidationError("--judge-context-token-file: cannot read \(file)")
            }
        }
        do {
            return StenographerJudgeContext(client: try StenographerClient(baseURL: url, token: token))
        } catch let error as StenographerClientError {
            throw ValidationError("--judge-context: \(error.message)")
        }
    }

    private func note(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
