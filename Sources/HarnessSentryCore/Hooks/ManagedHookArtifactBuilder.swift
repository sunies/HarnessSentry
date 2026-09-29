import Foundation

/// Generates integrations whose official format is not a mergeable JSON hook file.
/// Every artifact is intentionally small and forwards only lifecycle/tool metadata.
public enum ManagedHookArtifactBuilder {
    public static let supportedAdapterIDs = ["kimi-cli", "cline"]
    public static let marker = "HarnessSentry managed A3 integration"

    public static func data(executablePath: String, adapterID: String) throws -> Data {
        let text: String
        switch adapterID {
        case "kimi-cli":
            text = kimiBlock(executablePath: executablePath)
        case "cline":
            text = clinePlugin(executablePath: executablePath)
        default:
            throw HookConfigurationEditingError.unsupportedAdapter(adapterID)
        }
        return Data(text.utf8)
    }

    public static func kimiBlock(executablePath: String) -> String {
        let events = ["SessionStart", "PostToolUse", "PostToolUseFailure", "Stop"]
        let rules = events.map { event in
            let command = shellCommand(executablePath: executablePath, adapterID: "kimi-cli", event: event)
            return """
            [[hooks]]
            event = \(tomlString(event))
            command = \(tomlString(command))
            timeout = 5
            """
        }.joined(separator: "\n\n")
        return """
        # BEGIN \(marker)
        \(rules)
        # END \(marker)
        """
    }

    public static func clinePlugin(executablePath: String) -> String {
        let executable = javascriptString(executablePath)
        return """
        // \(marker)
        import { spawn } from "node:child_process"

        const receiver = \(executable)
        let currentSession = { id: undefined, cwd: undefined }

        function compactInput(input) {
          if (!input || typeof input !== "object") return {}
          const keys = ["command", "path", "file_path", "filePath", "url", "target", "destination", "args"]
          return Object.fromEntries(keys.filter((key) => input[key] !== undefined).map((key) => [key, input[key]]))
        }

        function emit(event, payload = {}) {
          try {
            const child = spawn(receiver, ["--adapter", "cline", "--event", event], {
              stdio: ["pipe", "ignore", "ignore"],
              detached: true,
            })
            child.stdin.end(JSON.stringify({
              hook_event_name: event,
              session_id: payload.session_id ?? currentSession.id,
              cwd: payload.cwd ?? currentSession.cwd,
              ...payload,
            }))
            child.unref()
          } catch (_) {}
        }

        export default {
          name: "harnesssentry-audit",
          manifest: { capabilities: ["hooks"] },
          setup(_api, ctx) {
            currentSession = {
              id: ctx?.session?.sessionId,
              cwd: ctx?.workspaceInfo?.rootPath ?? ctx?.workspaceInfo?.cwd,
            }
          },
          hooks: {
            beforeRun(ctx) {
              emit("SessionStart", {
                session_id: ctx?.session?.sessionId,
                cwd: ctx?.workspaceInfo?.rootPath ?? ctx?.workspaceInfo?.cwd,
              })
            },
            afterTool({ toolCall, input, result }) {
              emit(result?.isError ? "PostToolUseFailure" : "PostToolUse", {
                tool_name: toolCall?.toolName ?? toolCall?.name,
                tool_input: compactInput(input ?? toolCall?.input),
              })
            },
            afterRun({ result }) {
              emit(result?.status === "failed" ? "StopFailure" : "Stop", { status: result?.status })
            },
          },
        }
        """
    }

    public static func openCodeProjectPlugin(executablePath: String) -> String {
        let executable = javascriptString(executablePath)
        return """
        // \(marker)
        import { Plugin } from "@opencode/plugin"
        import { spawn } from "node:child_process"

        const receiver = \(executable)

        function compactInput(input) {
          if (!input || typeof input !== "object") return {}
          const keys = ["command", "path", "file_path", "filePath", "url", "target", "destination", "args"]
          return Object.fromEntries(keys.filter((key) => input[key] !== undefined).map((key) => [key, input[key]]))
        }

        function emit(eventName, event = {}) {
          try {
            const child = spawn(receiver, ["--adapter", "opencode", "--event", eventName], {
              stdio: ["pipe", "ignore", "ignore"],
              detached: true,
            })
            child.stdin.end(JSON.stringify({
              hook_event_name: eventName,
              session_id: event.sessionID ?? event.session_id,
              cwd: event.cwd ?? event.workingDirectory,
              tool_name: event.tool ?? event.toolName,
              tool_input: compactInput(event.input),
              status: event.status,
            }))
            child.unref()
          } catch (_) {}
        }

        const v2 = Plugin.define({
          id: "harnesssentry-audit",
          async setup(ctx) {
            await ctx.tool.hook("execute.after", (event) => {
              emit(event.status === "error" ? "PostToolUseFailure" : "PostToolUse", event)
            })
          },
        })

        export default {
          ...v2,
          async server() {
            return {
              "tool.execute.after": async (input, output) => {
                emit(output?.error ? "PostToolUseFailure" : "PostToolUse", { ...input, ...output })
              },
            }
          },
        }
        """
    }

    private static func shellCommand(executablePath: String, adapterID: String, event: String) -> String {
        "\(shellQuote(executablePath)) --adapter \(shellQuote(adapterID)) --event \(shellQuote(event))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func javascriptString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }
}
