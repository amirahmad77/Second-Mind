import SwiftUI

// ─── EntitiesView ─────────────────────────────────────────────────────────────
//
// "People & entities" surface. Reads the in-memory entity index AtomStore builds
// as atoms refine (`allEntities()` / `atoms(forEntity:)`) and presents it grouped
// by kind: person / org / project / topic.
//
// Each row is an entity name + its live mention count. Tapping a row expands an
// inline list of the atoms that mention it; tapping one of those routes back to
// the host via `onPickAtom` (MacSidebar posts `.nousSelectAtom`).
//
// Phosphor Instrument aesthetic: inkVoid field, mono labels, phosphor-tinted
// section accents, calm motion. Presented as a self-contained sheet from MacSidebar.

struct EntitiesView: View {
    let store: AtomStore
    /// Host opens the picked atom (MacSidebar posts `.nousSelectAtom`).
    var onPickAtom: (AtomSnapshot) -> Void
    var onClose: () -> Void

    /// Display order + presentation metadata for the four entity kinds.
    private enum Kind: String, CaseIterable {
        case person, org, project, topic

        var label: String {
            switch self {
            case .person:  "// people"
            case .org:     "// orgs"
            case .project: "// projects"
            case .topic:   "// topics"
            }
        }

        var icon: String {
            switch self {
            case .person:  "person"
            case .org:     "building.2"
            case .project: "folder"
            case .topic:   "number"
            }
        }

        @MainActor var accent: Color {
            switch self {
            case .person:  NSColorToken.Phos.cyan
            case .org:     NSColorToken.Phos.blue
            case .project: NSColorToken.Phos.green
            case .topic:   NSColorToken.Phos.violet
            }
        }
    }

    private struct Entity: Identifiable {
        let name: String
        let kind: String
        let count: Int
        var id: String { name.lowercased() }
    }

    /// Lowercased name of the currently-expanded row (only one open at a time).
    @State private var expanded: String?
    /// Snapshot captured on appear so layout is stable across expand redraws.
    @State private var entities: [Entity] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            NSColorToken.inkVoid.ignoresSafeArea()

            if entities.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NSpace.xl) {
                        ForEach(Kind.allCases, id: \.self) { kind in
                            let rows = entities.filter { $0.kind == kind.rawValue }
                            if !rows.isEmpty {
                                section(kind: kind, rows: rows)
                            }
                        }
                    }
                    .padding(.horizontal, NSpace.lg)
                    .padding(.top, NSpace.x4)
                    .padding(.bottom, NSpace.xl)
                }
            }

            header
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear { reload() }
    }

    // MARK: – Header

    private var header: some View {
        HStack(spacing: NSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("// entities")
                    .font(NFont.mono(13))
                    .foregroundStyle(NSColorToken.textSecondary)
                Text("\(entities.count) tracked across your vault")
                    .font(NFont.monoSmall(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .monospacedDigit()
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NSColorToken.textGhost)
                    .padding(NSpace.sm)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(NSpace.md)
        .background(NSColorToken.inkVoid.opacity(0.9))
    }

    // MARK: – Section

    private func section(kind: Kind, rows: [Entity]) -> some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            HStack(spacing: NSpace.sm) {
                Image(systemName: kind.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(kind.accent)
                Text(kind.label)
                    .font(NFont.monoSmall(11))
                    .foregroundStyle(NSColorToken.textTertiary)
                Spacer(minLength: 0)
                Text("\(rows.count)")
                    .font(NFont.monoSmall(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .monospacedDigit()
            }
            .padding(.horizontal, NSpace.xs)

            VStack(spacing: 1) {
                ForEach(rows) { entity in
                    entityRow(entity, accent: kind.accent)
                }
            }
        }
    }

    // MARK: – Entity row

    private func entityRow(_ entity: Entity, accent: Color) -> some View {
        let isOpen = expanded == entity.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.nEaseOutQuint) {
                    expanded = isOpen ? nil : entity.id
                }
            } label: {
                HStack(spacing: NSpace.sm) {
                    Circle()
                        .fill(accent)
                        .frame(width: 5, height: 5)
                    Text(entity.name)
                        .font(NFont.body(14))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: NSpace.sm)
                    Text("\(entity.count)")
                        .font(NFont.monoSmall(10))
                        .foregroundStyle(NSColorToken.textGhost)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(NSColorToken.textGhost)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, NSpace.sm)
                .padding(.horizontal, NSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOpen ? NSColorToken.inkRaised.opacity(0.7) : NSColorToken.inkPaper)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                expandedAtoms(for: entity, accent: accent)
            }
        }
    }

    private func expandedAtoms(for entity: Entity, accent: Color) -> some View {
        let mentions = store.atoms(forEntity: entity.name)
        return VStack(alignment: .leading, spacing: 1) {
            if mentions.isEmpty {
                Text("// no live mentions")
                    .font(NFont.monoSmall(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .padding(.vertical, NSpace.sm)
                    .padding(.leading, NSpace.xl)
            } else {
                ForEach(mentions) { atom in
                    Button {
                        onPickAtom(atom)
                    } label: {
                        HStack(spacing: NSpace.sm) {
                            Circle()
                                .fill(atom.type.phosphor)
                                .frame(width: 4, height: 4)
                            Text(atom.oneLiner)
                                .font(NFont.body(13))
                                .foregroundStyle(NSColorToken.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, NSpace.xs)
                        .padding(.leading, NSpace.xl)
                        .padding(.trailing, NSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, NSpace.xs)
        .padding(.bottom, NSpace.sm)
    }

    // MARK: – Empty state

    private var emptyState: some View {
        VStack(spacing: NSpace.sm) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(NSColorToken.textGhost)
            Text("// no entities yet")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost)
            Text("people, orgs, and topics surface here as your notes refine")
                .font(NFont.monoSmall(10))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NSpace.xl)
    }

    // MARK: – Data

    private func reload() {
        entities = store.allEntities().map {
            Entity(name: $0.name, kind: $0.kind, count: $0.count)
        }
    }
}
