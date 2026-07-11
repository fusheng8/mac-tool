# Control Center Design QA

- source visual truth path: `/Users/fusheng/develop/code/other/fuhseng-mac-tool/docs/design/control-center-option-2.png`
- implementation screenshot path: `/Users/fusheng/develop/code/other/fuhseng-mac-tool/docs/design/control-center-implementation-default.png`
- minimum-size screenshot path: `/Users/fusheng/develop/code/other/fuhseng-mac-tool/docs/design/control-center-implementation-minimum.png`
- dark-mode screenshot path: `/Users/fusheng/develop/code/other/fuhseng-mac-tool/docs/design/control-center-implementation-dark.png`
- focused application-uninstaller screenshot path: `/Users/fusheng/develop/code/other/fuhseng-mac-tool/docs/design/application-uninstaller-implementation-dark.png`
- normalized side-by-side evidence: `/Users/fusheng/develop/code/other/fuhseng-mac-tool/docs/design/control-center-comparison-final.png`
- viewport: default `1080 × 720` points at 2×; minimum `920 × 620` points at 2×
- state: healthy overview, light and dark Aqua; selected source visual uses the same overview route with a Finder-extension warning banner

## Findings

No actionable P0, P1, or P2 visual differences remain.

- The implementation intentionally includes sidebar search, which is required by the product plan but absent from the selected concept image.
- The source shows a Finder permission warning while the final implementation capture is in the healthy state. The issue banner was checked separately in code and runtime routing; this is a data-state difference, not layout drift.
- Increased-contrast colors are implemented through the shared color tokens. A separate system-level increased-contrast screenshot was not captured to avoid changing the user's global accessibility setting; this remains a P3 test gap.

## Fidelity Surfaces

- Fonts and typography: SF system typography is retained; page title, section heading, body, caption, weight hierarchy, wrapping, and truncation match the selected macOS utility direction.
- Spacing and layout rhythm: 220-point sidebar, 24-point content inset, 8-point spacing system, 10–12-point radii, two-column workbench, and full-width disclosure match the source. The minimum viewport has no horizontal scrollbar or clipped persistent action.
- Colors and visual tokens: low-saturation blue is the only brand accent; green, amber, and red are semantic. Light and real `.darkAqua` captures show resolved surfaces, text, borders, and selection colors.
- Image and icon fidelity: the product uses SF Symbols and real application icons; no emoji, placeholder art, handcrafted SVG, or fake asset is used.
- Copy and content: tool names and primary actions match the redesigned information architecture. “最近活动/最近任务” is absent from the source tree and UI.

## Full-view Comparison Evidence

`control-center-comparison-final.png` places the selected visual and implementation in one image at matched height. The final implementation preserves the source's hierarchy: sidebar, status line, optional issue area, “现在可以做什么” heading, paired tool columns, single primary action per row, and bottom system-information disclosure.

## Focused Region Evidence

The application-uninstaller capture verifies the new default “可卸载” filter, compact list rows, source/size/admin/recent-use metadata, right-hand read-only inspection panel, and advanced batch-mode entry. A focused overview crop was unnecessary because typography, icons, controls, and row separators are legible in the normalized full-view comparison.

## Comparison History

1. Initial runtime pass found a P0 cross-hierarchy Auto Layout exception in `ApplicationUninstallerView` before the control center could open. Width constraints are now activated only after views share a hierarchy. Post-fix evidence: all seven routes opened in one runtime session; the uninstaller screenshot rendered successfully.
2. Second runtime pass found a P0 separator constraint ordering exception in `ControlCenterOverviewView`. The separator is now added before its width constraint is activated. Post-fix evidence: default and minimum overview screenshots rendered without exceptions.
3. First visual comparison found a P2 half-width system-information disclosure. It is now constrained to the overview stack width. Post-fix evidence: `control-center-comparison-final.png` shows a full-width disclosure matching the source.
4. Dark-mode inspection found P2 light-surface leakage and stale sidebar colors. Search, select, text-button, icon-button, compact uninstaller rows, and sidebar items now resolve from dynamic tokens and refresh on appearance changes. Post-fix evidence: `control-center-implementation-dark.png` and `application-uninstaller-implementation-dark.png`.

## Primary Interactions Tested

- Opened overview, clipboard, Finder, archive, displays, ports, uninstall, and preferences through the unified deep-link route.
- Verified the default and minimum window sizes, page restoration, sidebar route changes, and real `.darkAqua` appearance.
- Verified that opening each route produces no AppKit constraint exception after the fixes.
- Verified the application-uninstaller scan and empty inspection state without executing destructive actions.

## Implementation Checklist

- [x] Selected visual reproduced as the control-center shell and overview.
- [x] Recent activity removed.
- [x] Default, minimum, light, and dark appearance evidence captured.
- [x] P0/P1/P2 findings fixed and re-captured.
- [x] Production App bundle builds successfully.

final result: passed
