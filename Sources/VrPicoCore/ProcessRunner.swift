import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut(command: String)
    /// 可执行文件不存在或没有执行权限。
    case notExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "启动进程失败：\(reason)"
        case .timedOut(let command):
            return "命令超时（已强制结束）：\(command)"
        case .notExecutable(let path):
            return "不可执行的文件：\(path)"
        }
    }
}

/// 统一的子进程执行入口。
///
/// 始终以「可执行文件 + 参数数组」的方式调用，**绝不拼接 shell 字符串**——
/// 服务器地址、token、设备序列号都是用户输入，拼字符串会引入命令注入和转义问题。
public enum ProcessRunner {

    public static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 20
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessRunnerError.notExecutable(executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // adb 不该读 stdin；接 /dev/null 防止它意外等待输入挂住。
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // 父进程必须放掉写端，否则读取端永远等不到 EOF。
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        // 必须在等退出前就并发排空管道：adb 输出超过管道缓冲区（64KB）时，
        // 先 waitUntilExit 再读会死锁。
        async let stdoutData = drain(stdoutPipe.fileHandleForReading)
        async let stderrData = drain(stderrPipe.fileHandleForReading)

        let timedOut = await waitForExit(process, timeout: timeout)

        let stdout = decode(await stdoutData)
        let stderr = decode(await stderrData)

        if timedOut {
            throw ProcessRunnerError.timedOut(
                command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))"
            )
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// 返回是否因为超时被强杀。
    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning {
            if Date() >= deadline {
                process.terminate() // SIGTERM
                let killDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < killDeadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return false
    }

    /// 在后台线程上把管道读干净。读取端会在所有写端关闭后拿到 EOF。
    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var data = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                handle.closeFile()
                continuation.resume(returning: data)
            }
        }
    }

    /// 命令输出理论上都是 UTF-8，但设备型号里混进坏字节不该让整个流程失败。
    private static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
