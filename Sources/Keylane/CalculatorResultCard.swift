import SwiftUI
import KeylaneCore

struct CalculatorResultCard: View {
    let expression: String
    let result: String
    let selected: Bool
    let conversionDetail: String?
    @AppStorage("calculatorSyntaxHighlighting") private var syntaxHighlighting = true
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) {
            column(styledExpression, badge: conversionDetail == nil ? operation : "换算")
            if conversionDetail == CalculatorLauncherModule.colorDetail, let sample = CalculatorColor(result)?.color {
                column(Text(result).monospacedDigit(), badge: conversionDetail ?? "",
                       swatch: Color(red: sample.red, green: sample.green, blue: sample.blue, opacity: sample.alpha))
            } else {
                column(Text(result).monospacedDigit(), badge: conversionDetail ?? resultInWords)
            }
        }
        .frame(height: 126)
        .overlay {
            VStack(spacing: 0) {
                divider
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 40)
                divider
            }
            .accessibilityHidden(true)
        }
        .background(
            .primary.opacity(selected ? (contrast == .increased ? 0.20 : 0.105) : 0.045),
            in: RoundedRectangle(cornerRadius: VisualStyle.selectionRadius)
        )
        .contentShape(RoundedRectangle(cornerRadius: VisualStyle.selectionRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(expression) 等于 \(result) \(conversionDetail ?? "")"))
        .accessibilityHint(conversionDetail == CalculatorLauncherModule.colorDetail ? "选择复制格式" : "复制计算结果")
    }

    private func column(_ text: Text, badge: String, swatch: Color? = nil) -> some View {
        VStack(spacing: 0) {
            HStack {
                if let swatch {
                    RoundedRectangle(cornerRadius: 6).fill(swatch).frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.20)))
                }
                text.font(.system(size: 25, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.45)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(badge)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(.primary.opacity(0.13))
            .frame(width: 1).frame(maxHeight: .infinity)
    }

    private var displayedExpression: String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop(while: { $0 == "=" || $0 == "＝" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var styledExpression: Text {
        guard syntaxHighlighting else { return Text(displayedExpression) }
        var text = AttributedString()
        for character in displayedExpression {
            var part = AttributedString(String(character))
            if "+-−＋－*/×÷＊／^%＾％".contains(character) { part.foregroundColor = .secondary }
            text.append(part)
        }
        return Text(text)
    }

    private var operation: String {
        let operators = displayedExpression.filter { "+-−＋－*/×÷＊／^%＾％".contains($0) }
        guard operators.count == 1, let symbol = operators.first,
              displayedExpression.first != symbol else { return "算式" }
        switch symbol {
        case "+", "＋": return "加法"
        case "-", "−", "－": return "减法"
        case "*", "×", "＊": return "乘法"
        case "/", "÷", "／": return "除法"
        case "^", "＾": return "乘方"
        case "%", "％": return "百分比"
        default: return "算式"
        }
    }

    private var resultInWords: String {
        let decimal = Locale.current.decimalSeparator ?? "."
        guard let number = Double(result.replacingOccurrences(of: decimal, with: ".")),
              abs(number) < 1_000_000_000 else { return "结果" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        let words = formatter.string(from: NSNumber(value: number)) ?? "结果"
        return words.count <= 42 ? words : "结果"
    }
}
