# NOUS — Visual System v1

Dark phosphor register. iOS 17+, SwiftUI + Metal. Companion to `.impeccable.md` and the design brief.

---

## 1. Color Tokens (OKLCH → sRGB for Color asset catalog)

All values OKLCH. Convert via `Color(red:green:blue:)` after sRGB convert. Tint neutrals toward `--brand-hue: 220` (cyan-blue), chroma 0.005-0.012.

### Ground / surfaces

| Token | OKLCH | Notes |
|---|---|---|
| `ink.void` | `oklch(0.10 0.012 240)` | App ground. Near-black, blue-violet tint. NOT #000. |
| `ink.paper` | `oklch(0.14 0.010 240)` | Stream surface. Subtle lift from void. |
| `ink.raised` | `oklch(0.18 0.008 240)` | Atom-detail canvas, search sheet. |
| `ink.membrane` | `oklch(0.22 0.006 240)` @ 0.55 alpha | `.ultraThinMaterial` overlay base. |
| `ink.scrim` | `oklch(0.06 0.012 240)` @ 0.50 alpha | Behind overlays, dims Stream. |

### Type

| Token | OKLCH | Use |
|---|---|---|
| `text.primary` | `oklch(0.95 0.005 240)` | Atom body, headers. NOT pure white. |
| `text.secondary` | `oklch(0.72 0.008 240)` | Day-header counts, related-strip body. |
| `text.tertiary` | `oklch(0.52 0.010 240)` | Timestamps, system mono labels. |
| `text.ghost` | `oklch(0.36 0.012 240)` | Empty-state hints, disabled. |

Body line-height: `1.55` (dark needs +0.1 over light baseline). Cap line length 65–75ch (≈ 28-32 em on iPhone).

### Phosphor accents (use ≤10% visual weight, NEVER as text fill, NEVER as gradient)

| Token | OKLCH | Hue | Reserved use |
|---|---|---|---|
| `phos.cyan` | `oklch(0.82 0.16 200)` | cyan | Thought · default Orb idle glow |
| `phos.blue` | `oklch(0.74 0.20 250)` | electric blue | Decision · search match underline |
| `phos.green` | `oklch(0.86 0.20 145)` | CRT green | Task · sync OK (invisible v1) |
| `phos.amber` | `oklch(0.84 0.18 75)` | amber-yellow | Meeting · refining aura |
| `phos.orange` | `oklch(0.74 0.20 45)` | hazard orange | Question · attention/error |
| `phos.violet` | `oklch(0.70 0.18 295)` | violet | Reference · backlink-rich atom (>3 backlinks) |

Diffused-aura rule: phosphor color sits BEHIND `.ultraThinMaterialDark`, blur radius ≥ 60pt, opacity ≤ 0.15. Never stroked outline. Glow = light through fog.

### Atom-type → dot color map (final v1)

| Type | Color | Symbol (in legend only) |
|---|---|---|
| thought | `phos.cyan` | `·` |
| task | `phos.green` | `·` |
| meeting | `phos.amber` | `·` |
| decision | `phos.blue` | `·` |
| question | `phos.orange` | `·` |
| reference | `phos.violet` | `·` |

Dot = 6pt circle, `.shadow(color: phos.X.opacity(0.35), radius: 4)` halo. No outline. Visible only at atom-row left margin.

---

## 2. Typography

Reflex-fonts list (Inter, Fraunces, Plex, Space*, Instrument*, DM*, Outfit, Jakarta) BANNED.

### Picks

| Role | Font | License | Why |
|---|---|---|---|
| Display (day headers, hero moments) | **Migra** (Pangram Pangram) — `Migra Italic Light` for day headers | Commercial license needed | Instrument-panel display w/ humanist warmth. Italic = hand-set vibe w/o handwriting cost. Survives lowercase well. |
| Body (atom text, detail) | **Söhne Buch** (Klim) | Commercial | Refined humanist. High legibility on dark @ small sizes. Brand neutral. |
| Mono (timestamps, system, counts, all UI chrome) | **Berkeley Mono** (US Graphics) | Commercial | Instrument register, narrow proportions, beautiful 0/O distinction. Single-source identity for system layer. |

**Fallback set if licenses unavailable:** Display = `Reckless Light Italic` (Displaay) → `GT Maru` (Grilli). Body = `National 2` (Klim) → `Söhne` family. Mono = `Departure Mono` (free, terminal-grade) → `Commit Mono`.

Audition during build: render each across day-header, atom one-liner, timestamp, search result row on dark before final pick.

### Scale (rem-equivalent, fixed for app UI — no fluid clamp)

App UI = fixed scale, 1.25 ratio.

| Token | Size | Weight | Usage |
|---|---|---|---|
| `type.day-header` | 28pt | Light Italic (Migra) | "tuesday" |
| `type.day-meta` | 11pt | Mono regular (Berkeley) | "· 7 atoms · 1 mtg" |
| `type.atom-line` | 16pt | Regular (Söhne) | atom one-liner |
| `type.atom-meta` | 11pt | Mono regular (Berkeley) | "08:12 · from meeting" |
| `type.detail-body` | 17pt | Regular (Söhne), line-height 1.55 | atom-detail body |
| `type.tag` | 10pt | Mono uppercase tracking 0.08em (Berkeley) | smart-tag chips |
| `type.system` | 12pt | Mono regular (Berkeley) | empty/error/state lines |

**Rules**: lowercase by default for system text. Mono ONLY for system / numeric / metadata — never decorative. No all-caps body. Cap atom line length to 32em max width.

---

## 3. Spacing & Layout

4pt scale, semantic tokens.

| Token | pt |
|---|---|
| `space.xs` | 4 |
| `space.sm` | 8 |
| `space.md` | 12 |
| `space.lg` | 16 |
| `space.xl` | 24 |
| `space.2xl` | 32 |
| `space.3xl` | 48 |
| `space.4xl` | 64 |
| `space.5xl` | 96 |

Stream rhythm:
- Day-header top padding: `space.4xl` (64) — generous breathing.
- Day-header → first atom: `space.lg` (16).
- Atom → atom: `space.md` (12).
- Atom row internal: dot `space.md` from text leading edge.
- Stream horizontal padding: `space.xl` (24).
- Orb anchor: `space.xl` (24) from safe-area bottom, centered horizontal.

Asymmetry: day-header left-aligned, count-meta right-aligned on same baseline. Atom dot hangs in left gutter (negative leading space) — text aligns to one consistent vertical rule.

---

## 4. The Orb — Concept Spec

### Identity
Liquid phosphor sphere. Lives. Size: 64pt diameter idle, 88pt voice-active. Anchored bottom-center, floating 24pt above safe-area.

### Render stack
SwiftUI `Canvas` + Metal shader via `ShaderLibrary` (iOS 17 `colorEffect`, `distortionEffect`, `layerEffect`). NOT a static gradient.

```
ZStack {
  // Layer 1: outer halo — radial phosphor bloom
  Circle().fill(RadialGradient(phos.cyan.opacity(0.0)..0.35))
    .frame(72pt → 96pt by state)
    .blur(radius: 32)

  // Layer 2: liquid body — Metal shader
  Circle()
    .fill(.ultraThinMaterial)
    .colorEffect(ShaderLibrary.orbLiquid(
      .float(time),
      .float(audioAmplitude),  // 0..1
      .float2(touchPoint),
      .color(phos.currentState)
    ))
    .frame(64pt)

  // Layer 3: meniscus — thin rim highlight, 1pt
  Circle().stroke(
    LinearGradient(text.primary.opacity(0.18) → .clear),
    lineWidth: 0.5
  )
}
```

### Shader sketch (Metal, conceptual)

```metal
// orbLiquid.metal — colorEffect signature
[[ stitchable ]] half4 orbLiquid(
    float2 pos, half4 color,
    float time, float amp, float2 touch, half4 phos
) {
    float2 uv = (pos / 64.0) - 0.5;
    float r = length(uv);

    // Slow simplex flow — idle "breathing"
    float flow = simplex3(float3(uv * 2.0, time * 0.18));

    // Voice boil — amp drives turbulence frequency + amplitude
    float boil = simplex3(float3(uv * (4.0 + amp * 6.0), time * (0.6 + amp * 2.5)));
    float turbulence = mix(flow * 0.15, boil * (0.25 + amp * 0.5), amp);

    // Touch attractor — fluid bulge toward finger
    float touchPull = exp(-length(uv - touch) * 6.0) * 0.2;

    // Inner glow falloff
    float glow = smoothstep(0.5, 0.0, r + turbulence + touchPull);

    // Phosphor tint over membrane
    half3 rgb = mix(color.rgb, phos.rgb, glow * 0.7);
    half a = color.a + glow * 0.4;
    return half4(rgb, a);
}
```

(Real shader: simplex via lookup texture or polynomial approx for perf. Target 60fps iPhone 12, 120fps iPhone 15 Pro.)

### State visuals

| State | Halo color | Halo radius | Body shader params | Size | Motion |
|---|---|---|---|---|---|
| **idle** | `phos.cyan` @ 0.20 | 32pt blur | `amp=0`, slow flow | 64pt | Breathing: scale `0.97 → 1.03` over 4.2s, ease-in-out custom `(0.45, 0, 0.55, 1)` |
| **text-active** (tap) | `phos.cyan` @ 0.30 | 40pt | `amp=0.1`, gentle pulse on keystroke | 64pt | Morphs upward, attaches to keyboard top-edge as input membrane (matchedGeometry) |
| **voice-recording** (hold) | `phos.amber` rising → `phos.orange` if loud | 48 → 64pt | `amp` = mic RMS 0..1, `touch` = finger pos | 64 → 88pt | Shader boils. Halo throbs w/ amp. Continuous CHHaptic `intensity = amp * 0.6` |
| **voice-cancel-zone** (slid up & away) | desaturate to `text.ghost` | 24pt | freeze | 64pt | Body greys, mono caption appears: `// release to discard` |
| **search** (swipe-up) | `phos.blue` @ 0.25 | 56pt | flow accelerates, then settles | expands to full sheet | Orb stretches into top-of-screen translucent slab via `.matchedGeometryEffect` |
| **refining-broadcast** (any atom refining) | `phos.amber` @ 0.10 | 40pt | unchanged | 64pt | Halo pulses 0.06 → 0.12 alpha at 1.6s period — ambient indicator of background work |
| **sync-failed** (rare, only after 3 retries) | `phos.orange` @ 0.18 | 32pt | unchanged | 64pt | Halo holds 600ms then fades — only visual sync signal that exists |

### Gestures

| Gesture | Action | Haptic |
|---|---|---|
| tap | text input | soft tick on rise |
| long-press 200ms | begin voice | rising notification |
| release on Orb | commit voice | medium thud |
| slide up + release off Orb | cancel voice | crash |
| swipe up | open search sheet | soft tick |
| swipe left OR right | open Tasks page | soft tick |
| swipe down on expanded Orb | dismiss to idle | soft tick |

---

## 5. Motion System

Custom curves only. Built-in CSS easings = too weak.

### Curves (SwiftUI `Animation.timingCurve`)

```swift
extension Animation {
    static let easeOutQuint  = Animation.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.22)  // entries
    static let easeInOutQuint = Animation.timingCurve(0.77, 0.0, 0.175, 1.0, duration: 0.32) // morphs
    static let drawer        = Animation.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.42) // sheets, Orb expand
    static let breath        = Animation.timingCurve(0.45, 0.0, 0.55, 1.0, duration: 4.2)  // Orb idle
    static let press         = Animation.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.14)   // tap feedback
}
```

### Durations

| Element | Duration |
|---|---|
| Press feedback (Orb scale 1.0 → 0.97) | 140ms |
| Atom row tap → detail expand | 320ms `drawer` |
| Cross-fade raw ↔ refined w/ scanline glitch | 220ms total |
| Search sheet open | 380ms `drawer` |
| Tasks page slide-in (horizontal) | 360ms `drawer` |
| Day-header haptic-tick scrub feedback | 0 (instant) |
| Empty-state fade-in on first launch | 600ms `easeOutQuint` |
| Orb idle breath cycle | 4200ms `breath`, infinite |
| Voice cancel snap-back | 200ms `easeOutQuint` |

### Spring (use sparingly — ONLY for live/dragged elements)
```swift
.interactiveSpring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.1)
// Orb drag feedback, Stream pull-to-scrub, atom-detail in-place expand
```

### Stagger
- Stream first-load: atoms fade-up 8pt + opacity, 30ms stagger between rows, capped at 12 rows then no further delay.
- Search results: 25ms stagger, opacity only (no transform — they keep moving as user types).

### Cross-fade glitch (raw → refined)
1. t=0: raw text at opacity 1, blur 0.
2. t=80ms: blur → 2pt, opacity → 0.6, scanline overlay enters (1pt-tall horizontal phosphor.cyan stripe sweeps top→bottom 120ms).
3. t=160ms: snap to refined text, blur 1pt, opacity 0.6.
4. t=220ms: blur → 0, opacity → 1, scanline gone.

Blur masks the imperfect crossfade — eyes read it as a single transformation, not two strings swapping.

### Haptics (CHHapticEngine)

| Trigger | Pattern |
|---|---|
| Orb tap | sharpness 0.9, intensity 0.4, 8ms |
| Voice begin (long-press fire) | rising ramp 120ms, intensity 0.2 → 0.6 |
| Voice live (continuous) | sharpness 0.4, intensity = `mic_amp * 0.6` |
| Voice commit (release on Orb) | intensity 0.85, sharpness 0.6, 24ms (medium thud) |
| Voice cancel (release off) | crash: 3 quick transients @ 120ms |
| Stream scrub month boundary | sharpness 0.8, intensity 0.35, 6ms |
| Stream scrub year boundary | sharpness 0.5, intensity 0.9, 32ms |
| Save commit (text) | intensity 0.55, sharpness 0.5, 16ms |

### Reduce Motion
Respect `accessibilityReduceMotion`:
- Orb idle breath → static.
- Atom-detail expand → fade only, no scale/parallax.
- Cross-fade glitch → simple opacity swap, no blur, no scanline.
- Stream stagger → all rows fade together.
- Halos remain (color is not motion).

---

## 6. SwiftUI Primitives — Sketch

```swift
// MARK: - Tokens

enum NSColor {
    static let inkVoid     = Color(oklch: (0.10, 0.012, 240))
    static let inkPaper    = Color(oklch: (0.14, 0.010, 240))
    static let inkRaised   = Color(oklch: (0.18, 0.008, 240))
    static let textPrimary = Color(oklch: (0.95, 0.005, 240))
    static let textSecondary = Color(oklch: (0.72, 0.008, 240))
    static let textTertiary  = Color(oklch: (0.52, 0.010, 240))
    static let textGhost     = Color(oklch: (0.36, 0.012, 240))

    enum Phos {
        static let cyan   = Color(oklch: (0.82, 0.16, 200))
        static let blue   = Color(oklch: (0.74, 0.20, 250))
        static let green  = Color(oklch: (0.86, 0.20, 145))
        static let amber  = Color(oklch: (0.84, 0.18,  75))
        static let orange = Color(oklch: (0.74, 0.20,  45))
        static let violet = Color(oklch: (0.70, 0.18, 295))
    }
}

enum NSpace { static let xs:CGFloat=4, sm=8, md=12, lg=16, xl=24, xxl=32, xxxl=48, x4=64, x5=96 }

enum NFont {
    static let dayHeader     = Font.custom("Migra-LightItalic", size: 28)
    static let atomLine      = Font.custom("Söhne-Buch", size: 16)
    static let detailBody    = Font.custom("Söhne-Buch", size: 17)
    static let mono          = Font.custom("BerkeleyMono-Regular", size: 11)
    static let monoSystem    = Font.custom("BerkeleyMono-Regular", size: 12)
    static let tag           = Font.custom("BerkeleyMono-Regular", size: 10)
}

// MARK: - AtomDot

struct AtomDot: View {
    let type: AtomType
    var color: Color { type.phosphor }   // mapping in §1
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.35), radius: 4)
    }
}

// MARK: - DayHeader

struct DayHeader: View {
    let date: Date; let count: Int; let mtgCount: Int
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(date.lowercaseDayName).font(NFont.dayHeader).foregroundStyle(NSColor.textPrimary)
            Spacer(minLength: NSpace.lg)
            Text(metaString).font(NFont.mono).foregroundStyle(NSColor.textSecondary)
        }
        .padding(.top, NSpace.x4)
        .padding(.bottom, NSpace.lg)
    }
    var metaString: String {
        var s = "· \(count) atom\(count == 1 ? "" : "s")"
        if mtgCount > 0 { s += " · \(mtgCount) mtg" }
        return s
    }
}

// MARK: - AtomRow

struct AtomRow: View {
    let atom: Atom
    var body: some View {
        HStack(alignment: .top, spacing: NSpace.md) {
            AtomDot(type: atom.type).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(atom.displayLine)               // refined ?? raw
                    .font(NFont.atomLine)
                    .foregroundStyle(NSColor.textPrimary)
                    .lineLimit(3)                    // height cap
                    .truncationMode(.tail)
                Text(atom.metaLine)                  // "08:12 · from meeting"
                    .font(NFont.mono)
                    .foregroundStyle(NSColor.textTertiary)
            }
        }
        .padding(.vertical, NSpace.xs)
        .background(refiningAura)                    // diffused phos.amber when refining
    }

    @ViewBuilder var refiningAura: some View {
        if atom.isRefining {
            NSColor.Phos.amber.opacity(0.10)
                .blur(radius: 60)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Orb

struct Orb: View {
    @State private var time: Double = 0
    let state: OrbState         // .idle, .textActive, .voice(amp:), .search, .refiningBroadcast
    let onTap: () -> Void
    let onLongPressBegin: () -> Void
    // ...gesture wiring...

    var body: some View {
        TimelineView(.animation) { ctx in
            ZStack {
                // Halo
                Circle()
                    .fill(RadialGradient(
                        colors: [state.haloColor.opacity(state.haloAlpha), .clear],
                        center: .center, startRadius: 0,
                        endRadius: state.haloRadius))
                    .blur(radius: state.haloBlur)
                    .frame(width: state.haloFrame, height: state.haloFrame)

                // Liquid body
                Circle()
                    .fill(.ultraThinMaterial)
                    .colorEffect(ShaderLibrary.orbLiquid(
                        .float(ctx.date.timeIntervalSinceReferenceDate),
                        .float(state.amp),
                        .float2(state.touchPoint),
                        .color(state.phos)))
                    .frame(width: state.bodySize, height: state.bodySize)
                    .scaleEffect(state.breathScale)  // breathing only when .idle, drives via Animation.breath

                // Meniscus
                Circle()
                    .stroke(LinearGradient(
                        colors: [NSColor.textPrimary.opacity(0.18), .clear],
                        startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                    .frame(width: state.bodySize, height: state.bodySize)
            }
        }
    }
}
```

---

## 7. Anti-Slop Checklist (every screen passes before merge)

- [ ] No `Color.black` / `Color.white` literals — only tokens.
- [ ] No `LinearGradient` on text (gradient text BANNED).
- [ ] No `border-left`-style accent stripe (no thick leading bar on rows).
- [ ] No glassmorphism outside AI-membrane purpose.
- [ ] No "AI" labels, no sparkle icons, no magic-wand SF Symbols.
- [ ] No drop-shadow on rounded rect cards (we don't use cards — flat rows on inkPaper).
- [ ] No `.spring(...)` defaults — must be `interactiveSpring` w/ tuned response.
- [ ] No `Animation.easeIn` on entries — `easeOutQuint` only.
- [ ] No `scale(0)` entries — start `0.95` + opacity 0.
- [ ] No animation on keyboard-frequent actions (typing, scrolling).
- [ ] No system-default haptics — all via tuned CHHapticEngine patterns.
- [ ] Display font NOT in reflex-rejection list. Verified.
- [ ] Mono used only for system/numeric/metadata, never decorative.
- [ ] Atom row max height enforced (3-line cap → fade-mask).
- [ ] Reduce Motion path tested.

---

Ready for `/impeccable craft` build. Confirm or adjust.
