import Foundation
@testable import IslaKit

@main
struct ValidateLRC {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.count == 1, let path = arguments.first else {
            FileHandle.standardError.write(Data("usage: validate-lrc.sh /absolute/path/file.lrc\n".utf8))
            exit(2)
        }

        do {
            let raw = try String(contentsOfFile: path, encoding: .utf8)
            let document = try LocalLyricsDocument.parse(raw)
            print("title: \(document.metadata.title ?? "")")
            print("artist: \(document.metadata.artist ?? "")")
            print("lines: \(document.lines.count)")
            print("granularity: \(document.granularity.rawValue)")
        } catch {
            FileHandle.standardError.write(Data("invalid LRC: \(error)\n".utf8))
            exit(1)
        }
    }
}
