import CoreGraphics

/// Every icon Isla draws, drawn islandcn's way: Hugeicons' free set (MIT) with
/// islandcn's recipes (spec: plan 2026-11-15-islandcn-identical, slice S1).
///
/// Owner, 2026-11-15: islandcn's icons replace every SF Symbol Isla draws;
/// another app's icon stays that app's own. Where islandcn names a glyph for a
/// meaning (play, the music note, the timer, the check), its recipe is copied
/// exactly (`components/islandcn/glyphs.tsx`, commit 0011a41). Everything else
/// is the free set's nearest drawing, as an outline at the island weight, and
/// a symbol Isla drew filled is drawn solid with its details cut out — the rule
/// islandcn gives its own solid glyphs.
///
/// **The raw values are the SF Symbol names they replace.** Models, settings
/// tables and some forty test files already speak in those names (a HUD's
/// `symbol`, a device's candidate list), so keeping them as the vocabulary moved
/// the drawing and nothing else. A name with no case here draws nothing, which
/// is why `IslandGlyphTests` resolves every name the app can produce.
enum IslandGlyph: String, CaseIterable {
    // Transport and media
    case play = "play.fill"
    case pause = "pause.fill"
    case previousTrack = "backward.fill"
    case nextTrack = "forward.fill"
    case music = "music.note"
    case audioOutput = "speaker.wave.2.fill"
    case audioOutputOutline = "speaker.wave.2"
    case speakerLoud = "speaker.wave.3.fill"
    case speakerQuiet = "speaker.wave.1.fill"
    case speaker = "speaker.fill"
    case speakerMuted = "speaker.slash.fill"
    case microphone = "mic.fill"
    case microphoneMuted = "mic.slash.fill"
    case video = "video.fill"
    case videoOff = "video.slash"
    case videoAdd = "video.badge.plus"
    case stopwatch = "stopwatch.fill"
    case timer = "timer"
    case waveform = "waveform"
    case shuffle = "shuffle"
    case repeatAll = "repeat"
    case metronome = "metronome"
    case lyrics = "quote.bubble"
    case lyricsFilled = "quote.bubble.fill"
    case textQuote = "text.quote"
    case textLeft = "text.alignleft"
    case textBubble = "text.bubble"
    case wordSpacing = "text.word.spacing"
    case textAppend = "text.append"
    case translateBubble = "character.bubble"
    case translateBubbleFilled = "character.bubble.fill"
    case translate = "translate"
    case pencil = "pencil"

    // Arrows and status
    case download = "arrow.down.circle"
    case downloadFilled = "arrow.down.circle.fill"
    case downloadToLine = "arrow.down.to.line"
    case trayDownload = "tray.and.arrow.down"
    case trayDownloadFilled = "tray.and.arrow.down.fill"
    case save = "square.and.arrow.down"
    case openApp = "arrow.up.forward.app"
    case swap = "arrow.left.arrow.right"
    case width = "arrow.left.and.right"
    case arrowRight = "arrow.right"
    case refresh = "arrow.clockwise"
    case reset = "arrow.counterclockwise"
    case undo = "arrow.uturn.backward"
    case retry = "arrow.triangle.2.circlepath"
    case chevronRight = "chevron.right"
    case chevronLeft = "chevron.left"
    case chevronUp = "chevron.up"
    case chevronUpDown = "chevron.up.chevron.down"
    case compress = "rectangle.compress.vertical"
    case check = "checkmark"
    case checkCircle = "checkmark.circle.fill"
    case close = "xmark"
    case closeCircle = "xmark.circle"
    case closeCircleFilled = "xmark.circle.fill"
    case alertCircle = "exclamationmark.circle"
    case warning = "exclamationmark.bubble"
    case info = "info.circle"
    case plus = "plus"
    case minus = "minus"
    case plusCircle = "plus.circle"
    case minusCircle = "minus.circle"
    case more = "ellipsis"
    case search = "magnifyingglass"
    case history = "clock.arrow.circlepath"

    // Objects, files, clipboard, shelf
    case clipboard = "doc.on.clipboard"
    case clipboardList = "list.clipboard"
    case clipboardListFilled = "list.clipboard.fill"
    case clipboardBullets = "list.bullet.clipboard"
    case copy = "doc.on.doc"
    case copyFilled = "doc.on.doc.fill"
    case document = "doc"
    case documentText = "doc.text"
    case documentPlus = "doc.badge.plus"
    case folder = "folder"
    case folderAdd = "folder.badge.plus"
    case folderRemove = "folder.badge.minus"
    case tray = "tray"
    case trayFull = "tray.full"
    case trayFullFilled = "tray.full.fill"
    case trash = "trash"
    case photo = "photo"
    case link = "link"
    case code = "curlybraces"
    case swatch = "square.fill"
    case grid = "square.grid.2x2"
    case pin = "pin"
    case pinFilled = "pin.fill"
    case eye = "eye"
    case eyeSlash = "eye.slash"
    case hand = "hand.raised"
    case handFilled = "hand.raised.fill"
    case lock = "lock.fill"
    case lockDisplay = "lock.display"
    case key = "key"
    case keyboard = "keyboard"
    case keyboardFilled = "keyboard.fill"
    case gear = "gearshape"
    case gearFilled = "gearshape.fill"
    case power = "power"
    case star = "star"
    case starFilled = "star.fill"
    case stethoscope = "stethoscope"
    case personAdd = "person.crop.circle.badge.plus"
    case personRemove = "person.crop.circle.badge.minus"
    case at = "at"
    case camera = "camera.viewfinder"
    case globe = "globe"
    case boltOutline = "bolt"
    case bolt = "bolt.fill"
    case plug = "powerplug.fill"
    case batteryLow = "battery.25percent"
    case batteryCharging = "battery.100percent.bolt"
    case brightness = "sun.max.fill"
    case keyboardLight = "light.max"
    case pointerRays = "cursorarrow.rays"
    case pointerWait = "cursorarrow.motionlines"
    case pointerClick = "cursorarrow.click"
    case panelTop = "rectangle.topthird.inset.filled"
    case menuBar = "menubar.rectangle"
    case appearance = "circle.lefthalf.filled"
    case airDrop = "dot.radiowaves.up.forward"

    // Devices: where the sound plays
    case laptop = "laptopcomputer"
    case desktop = "desktopcomputer"
    case macMini = "macmini"
    case macStudio = "macstudio"
    case macPro = "macpro.gen3"
    case display = "display"
    case headphones = "headphones"
    case earbuds = "earbuds"
    case earPods = "earpods"
    case airPods = "airpods"
    case airPodsGen3 = "airpods.gen3"
    case airPodsGen4 = "airpods.gen4"
    case airPodsPro = "airpods.pro"
    case airPodsProGen3 = "airpods.pro.gen3"
    case airPodsMax = "airpods.max"
    case beatsHeadphones = "beats.headphones"
    case beatsEarphones = "beats.earphones"
    case powerbeats = "beats.powerbeats"
    case powerbeatsPro = "beats.powerbeats.pro"
    case powerbeatsProLegacy = "beats.powerbeatspro"
    case studioBuds = "beats.studiobuds"
    case studioBudsPlus = "beats.studiobuds.plus"
    case beatsFitPro = "beats.fitpro"
    case soloBuds = "beats.solobuds"
    case beatsPill = "beats.pill"
    case homePod = "homepod"
    case homePodMini = "homepod.mini"
    case hifiSpeaker = "hifispeaker"
    case appleTV = "appletv"
    case tv = "tv"
    case airPlay = "airplayaudio"
    case car = "car"

    /// How it is drawn. Computed once per glyph and size by `GlyphCache`.
    var recipe: GlyphRecipe {
        switch self {
        case .play: return Recipes.play
        case .pause: return Recipes.pause
        case .previousTrack: return Recipes.backward
        case .nextTrack: return Recipes.forward
        case .music: return Recipes.music
        case .audioOutput, .audioOutputOutline, .speakerLoud: return Recipes.audioOutput
        case .speakerQuiet: return GlyphRecipe(Hugeicons.volumeLow, parts: [.line, .fill])
        case .speaker: return GlyphRecipe(Array(Hugeicons.volumeHigh.prefix(1)), .fill)
        // The slash crosses a solid speaker, so it is cut a gap wide around it.
        case .speakerMuted: return GlyphRecipe([Hugeicons.volumeOff[0], Hugeicons.volumeOff[3]], parts: [.gap, .fill])
        case .microphone: return Recipes.microphone
        case .microphoneMuted: return GlyphRecipe(Hugeicons.micOff01, parts: [.fill, .gap, .line])
        case .video: return Recipes.video
        case .videoOff: return GlyphRecipe(Hugeicons.videoOff)
        case .videoAdd: return GlyphRecipe(Hugeicons.video01)
        case .stopwatch, .timer: return Recipes.timer
        case .waveform: return GlyphRecipe(Hugeicons.audioWave01)
        case .shuffle: return GlyphRecipe(Hugeicons.shuffle)
        case .repeatAll: return GlyphRecipe(Hugeicons.`repeat`)
        case .metronome: return GlyphRecipe(Hugeicons.metronome)
        case .lyrics: return GlyphRecipe(Hugeicons.messageSquareQuote)
        case .lyricsFilled: return GlyphRecipe(Hugeicons.messageSquareQuote, parts: [.fill, .cut, .cut])
        case .textQuote: return GlyphRecipe(Hugeicons.textQuote)
        case .textLeft: return GlyphRecipe(Hugeicons.textAlignLeft)
        case .textBubble: return GlyphRecipe(Hugeicons.message01)
        case .wordSpacing: return GlyphRecipe(Hugeicons.letterSpacing)
        case .textAppend: return GlyphRecipe(Hugeicons.textWrap)
        case .translateBubble: return GlyphRecipe(Hugeicons.bubbleChatTranslate)
        case .translateBubbleFilled: return GlyphRecipe(Hugeicons.bubbleChatTranslate, parts: [.fill, .cut])
        case .translate: return GlyphRecipe(Hugeicons.translate)
        case .pencil: return Recipes.pencil

        case .download, .downloadFilled, .downloadToLine, .trayDownload, .trayDownloadFilled, .save:
            return Recipes.download
        case .openApp: return GlyphRecipe(Hugeicons.arrowUpRight01)
        case .swap: return GlyphRecipe(Hugeicons.arrowDataTransferHorizontal)
        case .width: return GlyphRecipe(Hugeicons.arrowHorizontal)
        case .arrowRight: return GlyphRecipe(Hugeicons.arrowRight02)
        case .refresh: return GlyphRecipe(Hugeicons.refresh)
        case .reset: return GlyphRecipe(Hugeicons.undo)
        case .undo: return GlyphRecipe(Hugeicons.arrowTurnBackward)
        case .retry: return GlyphRecipe(Hugeicons.reload)
        // Hugeicons' "01" arrows are chevrons; the "02"s carry a shaft.
        case .chevronRight: return GlyphRecipe(Hugeicons.arrowRight01)
        case .chevronLeft: return GlyphRecipe(Hugeicons.arrowLeft01)
        case .chevronUp: return GlyphRecipe(Hugeicons.arrowUp01)
        case .chevronUpDown: return GlyphRecipe(Hugeicons.unfoldMore)
        case .compress: return GlyphRecipe(Hugeicons.unfoldLess)
        case .check: return Recipes.check
        case .checkCircle: return Recipes.checkCircle
        case .close: return Recipes.close
        case .closeCircle: return GlyphRecipe(Hugeicons.cancelCircle)
        case .closeCircleFilled: return GlyphRecipe(Hugeicons.cancelCircle, parts: [.fill, .cut])
        case .alertCircle: return GlyphRecipe(Hugeicons.alertCircle)
        case .warning: return Recipes.warning
        case .info: return GlyphRecipe(Hugeicons.informationCircle)
        case .plus: return GlyphRecipe(Hugeicons.add01)
        case .minus: return GlyphRecipe(Hugeicons.minusSign)
        case .plusCircle: return GlyphRecipe(Hugeicons.addCircle)
        case .minusCircle: return GlyphRecipe(Hugeicons.minusSignCircle)
        case .more: return GlyphRecipe(Hugeicons.moreHorizontal)
        case .search: return Recipes.search
        case .history: return GlyphRecipe(Hugeicons.history)

        case .clipboard, .clipboardList, .clipboardBullets: return GlyphRecipe(Hugeicons.task01)
        // The clip keeps its outline with a gap around it on the solid board.
        case .clipboardListFilled: return GlyphRecipe(Hugeicons.task01, parts: [.gap, .cut, .fill])
        case .copy, .copyFilled: return GlyphRecipe(Hugeicons.copy01)
        case .document: return GlyphRecipe(Hugeicons.fileEmpty01)
        case .documentText: return GlyphRecipe(Hugeicons.file02)
        case .documentPlus: return Recipes.documentPlus
        case .folder: return GlyphRecipe(Hugeicons.folder01)
        case .folderAdd: return GlyphRecipe(Hugeicons.folderAdd)
        case .folderRemove: return GlyphRecipe(Hugeicons.folderMinus)
        case .tray, .trayFull: return GlyphRecipe(Hugeicons.inbox)
        case .trayFullFilled: return GlyphRecipe(Hugeicons.inbox, parts: [.fill, .cut])
        case .trash: return GlyphRecipe(Hugeicons.delete02)
        case .photo: return GlyphRecipe(Hugeicons.image01)
        case .link: return GlyphRecipe(Hugeicons.link01)
        case .code: return GlyphRecipe(Hugeicons.braces)
        // A colour's swatch: a plain rounded square, solid.
        case .swatch: return GlyphRecipe([.rect(x: 3, y: 3, width: 18, height: 18, rx: 5)], .fill)
        case .grid: return GlyphRecipe(Hugeicons.gridView)
        case .pin: return GlyphRecipe(Hugeicons.pin)
        case .pinFilled: return GlyphRecipe(Hugeicons.pin, parts: [.line, .fill])
        case .eye: return GlyphRecipe(Hugeicons.view)
        case .eyeSlash: return GlyphRecipe(Hugeicons.viewOff)
        // The free set's hand is open strokes, which fill as a blot.
        case .hand, .handFilled: return GlyphRecipe(Hugeicons.hand)
        case .lock: return GlyphRecipe(Hugeicons.squareLock02, parts: [.cut, .line, .fill])
        case .lockDisplay: return GlyphRecipe(Hugeicons.lockComputer)
        case .key: return GlyphRecipe(Hugeicons.key01)
        case .keyboard, .keyboardFilled: return GlyphRecipe(Hugeicons.keyboard)
        case .gear: return GlyphRecipe(Hugeicons.settings01)
        case .gearFilled: return GlyphRecipe(Hugeicons.settings01, parts: [.fill, .cut])
        case .power: return GlyphRecipe(Hugeicons.shutDown)
        case .star: return GlyphRecipe(Hugeicons.star)
        case .starFilled: return Recipes.star
        case .stethoscope: return GlyphRecipe(Hugeicons.stethoscope)
        case .personAdd: return GlyphRecipe(Hugeicons.userAdd01)
        case .personRemove: return GlyphRecipe(Hugeicons.userMinus01)
        case .at: return GlyphRecipe(Hugeicons.at)
        case .camera: return GlyphRecipe(Hugeicons.camera01)
        case .globe: return Recipes.globe
        case .bolt, .boltOutline: return Recipes.bolt
        case .plug: return GlyphRecipe(Hugeicons.plug01, parts: [.line, .fill, .line, .cut])
        case .batteryLow: return GlyphRecipe(Hugeicons.batteryLow)
        case .batteryCharging: return Recipes.batteryCharging
        case .brightness: return GlyphRecipe(Hugeicons.sun03, parts: [.fill, .line])
        case .keyboardLight: return GlyphRecipe(Hugeicons.sun01)
        case .pointerRays, .pointerClick: return GlyphRecipe(Hugeicons.mousePointerClick)
        case .pointerWait: return GlyphRecipe(Hugeicons.cursorHold01)
        case .panelTop: return GlyphRecipe(Hugeicons.layoutTop)
        case .menuBar: return GlyphRecipe(Hugeicons.layoutAlignTop)
        case .appearance: return GlyphRecipe(Hugeicons.contrast)
        case .airDrop: return GlyphRecipe(Hugeicons.airdrop)

        case .laptop: return Recipes.laptop
        case .desktop, .macMini, .macStudio, .macPro, .display: return Recipes.desktop
        // The free set has no AirPods Max and no Beats: over-ear is the
        // headphones, in-ear the pair of buds, a speaker the speaker.
        case .headphones, .airPodsMax, .beatsHeadphones: return Recipes.headphones
        case .earbuds, .earPods, .airPods, .airPodsGen3, .airPodsGen4, .airPodsPro, .airPodsProGen3,
             .beatsEarphones, .powerbeats, .powerbeatsPro, .powerbeatsProLegacy, .studioBuds, .studioBudsPlus,
             .beatsFitPro, .soloBuds:
            return GlyphRecipe(Hugeicons.airpod03)
        case .beatsPill, .homePod, .homePodMini, .hifiSpeaker: return GlyphRecipe(Hugeicons.speaker01)
        case .appleTV, .tv: return GlyphRecipe(Hugeicons.tv01)
        case .airPlay: return GlyphRecipe(Hugeicons.airplayLine)
        case .car: return Recipes.car
        }
    }

    /// islandcn's own glyphs, copied from `glyphs.tsx` recipe for recipe.
    private enum Recipes {
        /// Triangle01's outline turned to point right, scaled to Pause's 16 unit
        /// height and set 0.4 units right of centre, as a play button's
        /// triangle sits (`playPlace`).
        static let playPlace = GlyphPlacement(at: CGPoint(x: 12.4, y: 12), scale: 0.8, turn: 90)

        static let timer = GlyphRecipe(Hugeicons.stopWatch, parts: [.heavy, .line, .cut])
        static let play = GlyphRecipe(Array(Hugeicons.triangle01.prefix(1)), .fill, place: playPlace)
        static let pause = GlyphRecipe(Hugeicons.pause, .fill)
        static let close = GlyphRecipe(Hugeicons.cancel01)
        /// Seek forward: two solid triangles. islandcn's player draws its
        /// previous and next track buttons with these (`PlayerForwardGlyph`).
        static let forward = GlyphRecipe(Hugeicons.fastForward, .fill)
        static let backward = GlyphRecipe(Hugeicons.fastForward, .fill, place: GlyphPlacement(mirror: true))
        /// Two beamed notes: solid heads on outline stems.
        static let music = GlyphRecipe(Hugeicons.musicNote03, parts: [.fill, .fill, .line, .line])
        /// A solid speaker with two waves stretched 1.35 times taller about the
        /// speaker's middle, without thickening them.
        static let audioOutput = GlyphRecipe(
            Array(Hugeicons.volumeHigh.prefix(1)), .fill,
            layers: [GlyphLayer(Array(Hugeicons.volumeHigh[1...2]), place: GlyphPlacement(stretch: 1.35))],
            view: GlyphRecipe.centredView(ink: 21, share: 21 / 27.5)
        )
        static let check = GlyphRecipe(Hugeicons.tick02)
        static let checkCircle = GlyphRecipe(Hugeicons.checkmarkCircle02)
        static let warning = GlyphRecipe(Hugeicons.alert02)
        static let documentPlus = GlyphRecipe(Hugeicons.filePlusCorner)
        static let download = GlyphRecipe(Hugeicons.download01)
        /// A pencil, without PencilEdit01's underline.
        static let pencil = GlyphRecipe(Array(Hugeicons.pencilEdit01.prefix(1)))
        static let search = GlyphRecipe(Hugeicons.search01)
        static let globe = GlyphRecipe(Hugeicons.globe02)
        static let microphone = GlyphRecipe(Hugeicons.mic01, parts: [.fill, .line])
        /// A solid camera body and lens, the viewfinder mark cut out.
        static let video = GlyphRecipe(Hugeicons.video02, parts: [.cut, .fill, .fill])
        static let headphones = GlyphRecipe(Hugeicons.headphones)
        /// A laptop: the screen an outline on a solid base.
        static let laptop = GlyphRecipe(Hugeicons.laptop, parts: [.line, .fill])
        static let desktop = GlyphRecipe(Hugeicons.computer)
        static let bolt = GlyphRecipe(Hugeicons.flash, .fill)
        static let batteryCharging = GlyphRecipe(Hugeicons.batteryCharging01)
        static let star = GlyphRecipe(Hugeicons.star, .fill)

        /// islandcn's hand-made car (`carBody`, `carWindows`): Car03's outline
        /// strokes joined into one closed body, its windows as holes 1.4 units
        /// in from the frame, and Car03's wheels set in with a gap.
        static let car = GlyphRecipe(
            [.path("M3.9 5H12.2394C12.2394 5 12.779 5 13.2586 5.048C14.158 5.132 14.9134 5.54 15.6688 6.56C16.4687 7.64 17.0837 9.008 17.8991 9.74C19.2541 10.9564 21.8321 10.58 21.976 13.16C22.012 14.48 22.012 15.92 21.952 16.16C21.8557 16.8667 21.3108 16.9821 20.633 17C20.0448 17.0156 19.3357 16.9721 18.9903 17L5.00893 17C2.1671 16.58 2.04719 15.98 2.01122 15.26C1.98723 13.04 2.00722 10.78 2.00722 10C2.22306 8.26 3.16234 6.2 3.64197 5.42Z")],
            .fill,
            layers: [
                GlyphLayer([.path("M4.4 6.4H7.9V8.6H3.6Z M10.1 6.4H13.3C14.2 6.6 14.9 7.4 15.8 8.6H10.1Z")], .cut),
                GlyphLayer(Array(Hugeicons.car03.prefix(2)), .inlay),
            ]
        )
    }
}
