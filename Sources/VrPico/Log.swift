import Foundation

/// 极简日志。
///
/// 直接写 stderr（无缓冲），这样从终端启动时能立刻看到，不必等进程退出——
/// 而 NSLog / os_log 要开 Console.app 才看得到，排查这类问题时太绕。
enum Log {
    static func debug(_ message: String) {
        FileHandle.standardError.write(Data("[VrPico] \(message)\n".utf8))
    }
}
