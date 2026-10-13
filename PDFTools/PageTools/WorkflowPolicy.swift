import Foundation

/// Monster Epic Phase 11 – Workflow-spezifische Erhaltungs-Policies.
struct WorkflowPolicy {

    let name: String
    let exactPageCount: Bool
    let preservesOrder: Bool
    let preservesText: Bool
    let preservesAnnotations: Bool
    let preservesExternalLinks: Bool
    let requiresInternalLinkRemap: Bool
    let preservesOutlines: Bool
    let preservesPageLabels: Bool
    let preservesForms: Bool
    let preservesAttachments: Bool
    let requiresRenderCheck: Bool

    init(
        name: String,
        exactPageCount: Bool = true,
        preservesOrder: Bool = true,
        preservesText: Bool = false,
        preservesAnnotations: Bool = false,
        preservesExternalLinks: Bool = false,
        requiresInternalLinkRemap: Bool = false,
        preservesOutlines: Bool = false,
        preservesPageLabels: Bool = false,
        preservesForms: Bool = false,
        preservesAttachments: Bool = false,
        requiresRenderCheck: Bool = true
    ) {
        self.name = name
        self.exactPageCount = exactPageCount
        self.preservesOrder = preservesOrder
        self.preservesText = preservesText
        self.preservesAnnotations = preservesAnnotations
        self.preservesExternalLinks = preservesExternalLinks
        self.requiresInternalLinkRemap = requiresInternalLinkRemap
        self.preservesOutlines = preservesOutlines
        self.preservesPageLabels = preservesPageLabels
        self.preservesForms = preservesForms
        self.preservesAttachments = preservesAttachments
        self.requiresRenderCheck = requiresRenderCheck
    }

    static let compression = WorkflowPolicy(
        name: "compression",
        preservesText: true,
        preservesAnnotations: true,
        preservesExternalLinks: true,
        preservesForms: true)

    static let merge = WorkflowPolicy(
        name: "merge",
        preservesText: true,
        preservesAnnotations: true,
        preservesExternalLinks: true)

    static let reorder = WorkflowPolicy(
        name: "reorder",
        preservesOrder: false,
        preservesText: true,
        preservesAnnotations: true,
        preservesExternalLinks: true,
        requiresInternalLinkRemap: true,
        preservesPageLabels: true,
        preservesForms: true)

    static func delete(removedPages: Int, from total: Int) -> WorkflowPolicy {
        WorkflowPolicy(name: "delete",
               exactPageCount: true,
               preservesOrder: true,
               preservesText: true,
               preservesAnnotations: true)
    }

    static let extract = WorkflowPolicy(
        name: "extract",
        preservesText: true,
        preservesAnnotations: true,
        preservesExternalLinks: true)

    static let split = WorkflowPolicy(
        name: "split",
        preservesText: true,
        preservesAnnotations: true)

    static let rotate = WorkflowPolicy(
        name: "rotate",
        preservesText: true,
        preservesAnnotations: true,
        preservesExternalLinks: true,
        preservesForms: true)
}
