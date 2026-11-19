import Foundation
import GitCore
import Observation
import SwiftUI

@MainActor @Observable
final class RebaseEditorModel {
    var plan: InteractiveRebasePlan
    var selection: String?
    var draggedCommit: String?
    var dropTarget: String?

    init(plan: InteractiveRebasePlan) {
        self.plan = plan
        selection = plan.steps.first?.oid
    }

    var selectedIndex: Int? { plan.steps.firstIndex { $0.oid == selection } }
    func commit(for step: RebaseStep) -> RebaseCommit? { plan.commits.first { $0.oid == step.oid } }

    func setAction(_ action: RebaseAction, at index: Int) {
        guard plan.steps.indices.contains(index) else { return }
        plan.steps[index].action = action
        if action == .squash {
            // Seed a complete combined message; subsequent edits stay literal.
            var messages: [String] = []
            for step in plan.steps.prefix(index + 1) where step.action != .drop {
                switch step.action {
                case .squash: if step.oid != plan.steps[index].oid { messages = [step.message] }
                case .fixup: break
                default: messages = [step.message]
                }
            }
            messages.append(commit(for: plan.steps[index])?.message ?? plan.steps[index].message)
            plan.steps[index].message = messages.joined(separator: "\n\n")
        } else {
            plan.steps[index].message = commit(for: plan.steps[index])?.message ?? plan.steps[index].message
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        plan.steps.move(fromOffsets: offsets, toOffset: destination)
    }

    func selectAdjacent(by delta: Int) {
        guard let index = selectedIndex, plan.steps.indices.contains(index + delta) else { return }
        selection = plan.steps[index + delta].oid
    }

    func moveSelection(by delta: Int) {
        guard let index = selectedIndex, plan.steps.indices.contains(index + delta) else { return }
        plan.steps.swapAt(index, index + delta)
    }

    func moveDraggedCommit(_ oid: String, to target: String) {
        defer { draggedCommit = nil; dropTarget = nil }
        guard let from = plan.steps.firstIndex(where: { $0.oid == oid }),
            let to = plan.steps.firstIndex(where: { $0.oid == target }), from != to
        else { return }
        move(from: [from], to: from < to ? to + 1 : to)
        selection = oid
    }

}
