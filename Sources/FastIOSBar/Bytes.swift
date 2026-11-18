import Foundation

/// Memory figures in the menu: MB below 1,000 MB, GB with one decimal above.
/// 1 MB = 1,048,576 bytes, as in `fast-ios measure`.
enum Bytes {
    static func mb(_ bytes: Int64) -> String {
        "\((bytes / 1_048_576).formatted()) MB"
    }

    static func short(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1000 { return "\(Int(mb.rounded())) MB" }
        return (mb / 1024).formatted(.number.precision(.fractionLength(1))) + " GB"
    }
}
