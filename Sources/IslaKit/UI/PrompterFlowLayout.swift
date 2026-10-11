import SwiftUI

/// The page's visible lines, each word placed where `PromptFlowLayout` put
/// it (spec 10.2). View glue only: positions, states and colours are all
/// decided elsewhere and tested there.
///
/// Only the lines in the region plus `PrompterStageMetrics.cullBuffer` above
/// and below are built, so a 100,000-word page costs what a short one does
/// (E-26). Equatable on what it draws, so the clock moving the page at 20 Hz
/// re-renders the offset around it and not these words: in a timer mode a
/// word's look does not depend on progress at all.
struct PrompterFlowLayout: View, Equatable {
    let layout: PromptLayout
    /// `PrompterStageModel.layoutStamp`: equal stamps are equal layouts.
    let layoutStamp: Int
    let script: PromptScript
    let lines: Range<Int>
    let style: PrompterStageStyle
    let font: Font
    let tracking: CGFloat
    /// Follow's current word; nil in the timer modes, which draw uniformly.
    let current: Int?
    let atEnd: Bool
    let uniform: Bool
    let tap: (Int) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.layoutStamp == b.layoutStamp && a.script.contentHash == b.script.contentHash
            && a.lines == b.lines && a.style == b.style && a.font == b.font && a.tracking == b.tracking
            && a.current == b.current && a.atEnd == b.atEnd && a.uniform == b.uniform
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(lines, id: \.self) { index in
                let line = layout.lines[index]
                if line.dividerAbove {
                    divider(above: line)
                }
                ForEach(line.items, id: \.self) { itemIndex in
                    word(layout.items[itemIndex], top: line.top)
                }
            }
        }
        .frame(width: layout.columnWidth, height: max(layout.height, 1), alignment: .topLeading)
    }

    private func word(_ item: PromptLineItem, top: Double) -> some View {
        let word = script.words[item.word]
        let state = PromptWordStates.state(of: item.word, in: script, current: current, atEnd: atEnd, uniform: uniform)
        let text: String
        if let fragment = item.fragment {
            text = String(Array(word.text)[fragment])
        } else {
            text = word.text
        }
        return Text(text)
            .font(font)
            .tracking(tracking)
            .italic(state == .cue)
            .foregroundStyle(style.color(for: state))
            .lineLimit(1)
            .fixedSize()
            .overlay(alignment: .bottom) {
                if style.underlines(state) {
                    // Under the word, never under the line: the mark moves
                    // with the word and the line keeps its shape (design note).
                    Rectangle()
                        .fill(style.highlightColor.color)
                        .frame(height: PrompterStageStyle.underlineWidth)
                        .offset(y: PrompterStageStyle.underlineWidth)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { tap(item.word) }
            .offset(x: item.x, y: top)
    }

    /// Spec 6.5: three dots, centred in the room above a paragraph.
    private func divider(above line: PromptLine) -> some View {
        let diameter = PrompterStageStyle.dividerDotDiameter
        let room = PromptFontMetrics.dividerSpacing + layout.metrics.lineSpacing
        return HStack(spacing: PrompterStageStyle.dividerDotSpacing) {
            ForEach(0..<PrompterStageStyle.dividerDotCount, id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(PrompterStageStyle.dividerOpacity(increaseContrast: style.increaseContrast)))
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: layout.columnWidth)
        .offset(y: line.top - room / 2 - diameter / 2)
    }
}
