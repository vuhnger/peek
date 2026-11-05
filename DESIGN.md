---
name: Peek
description: Menu bar status for GitHub Actions runs and GitLab pipelines on macOS 26.
colors:
  icon-ring-green: "#3FE07A"
  icon-squircle: "#15171C"
  run-amber: "#E0A829"
  passed-green: "#30D158"
  failed-red: "#FF453A"
  warning-orange: "#FF9F0A"
  branch-blue: "#0A84FF"
typography:
  repo-header:
    fontFamily: "SF Pro"
    fontSize: "13pt"
    fontWeight: 600
  body:
    fontFamily: "SF Pro"
    fontSize: "12pt"
    fontWeight: 400
  workflow:
    fontFamily: "SF Pro"
    fontSize: "12pt"
    fontWeight: 500
  branch:
    fontFamily: "SF Mono"
    fontSize: "10pt"
    fontWeight: 400
rounded:
  card: "22px"
spacing:
  outer: "10px"
  card-gap: "10px"
  card-x: "16px"
  card-y: "12px"
  indent: "26px"
components:
  repo-card:
    rounded: "{rounded.card}"
    padding: "12px 16px"
    width: "400px"
  notice-card:
    rounded: "{rounded.card}"
    padding: "0 16px"
    height: "64px"
  run-row:
    typography: "{typography.body}"
    height: "24px"
  branch-pill:
    textColor: "{colors.branch-blue}"
    typography: "{typography.branch}"
    padding: "0 7px"
    height: "20px"
---

# Design System: Peek

## Overview

Peek is flat and minimal with no decoration. It is dark only: the panel, the settings window and the menu bar strip all force the dark appearance. The panel is a column of Liquid Glass cards, one per repository, with no header and no footer. Color only carries run state.

**Key Characteristics:**
- Dark only.
- One regular-glass card per repository.
- No header or footer in the panel.
- Color means state, never decoration.

## Colors

The system colors (green, red, orange, blue) resolve to their dark-mode values listed in the frontmatter. Amber and the two icon colors are fixed values in code.

### Primary
- **Run amber**: running runs, the progress pie, the elapsed time and the progress bar. It also marks queued runs.

### Secondary
- **Passed green**: the passed glyph.
- **Failed red**: the failed glyph and the signed-out lock.
- **Warning orange**: overdue runs, warnings, the notice card tint (30% opacity) and inline error text in settings.
- **Branch blue**: branch pill text, on a 12% fill of the same blue.

### Neutral
Text uses the system hierarchy: primary for repository and workflow names, secondary for the owner, run titles and remaining time, tertiary for the PR number, the chevron and the age of finished runs.

### Named Rules
**The State Only Rule.** A color appears only to say what a run is doing. Nothing in the panel is colored for looks.

**The Stale Rule.** When the app is offline, rate limited or GitHub is not responding, repository cards turn grayscale at 60% opacity.

## Typography

**Font:** the system font (SF Pro). **Mono:** SF Mono for branch names only.

### Hierarchy
- **Repository header** (body text style): owner in secondary, then the repository name in semibold.
- **Workflow** (callout, medium): the workflow name on each run row, at most 150px wide.
- **Body** (callout): run titles, notices and settings messages.
- **Branch** (caption, monospaced): branch pills.

### Named Rules
**The Steady Digits Rule.** Every number that changes over time uses monospaced digits, so times and counts do not shift the row.

## Layout

The panel is 420px wide, with 10px outer padding and 10px between cards. Its cards start 1pt below the menu bar and 4pt left of the icon, kept 8pt from the screen edges. The panel grows to fit its cards up to the screen height minus 16px. Inside a card, rows are indented 26px under the header. A repository header is 22px tall, a branch pill 20px with 8px above it, and a run row 24px, plus 8px when it carries a progress bar. Settings is a single 520px wide window with 20px padding.

## Elevation & Depth

Depth comes only from Liquid Glass. Cards use regular glass inside one glass container. The panel window has no shadow and a clear background.

## Shapes

Cards have 22px rounded corners. Branch pills and the progress bar (4px tall) are capsules. Avatars are circles. State glyphs are circles or SF Symbols.

## Components

### Repository card
A header button with a state glyph (16px), `owner/name`, the age of the newest run and a chevron. The glyph shows a running or queued run if there is one, otherwise the result of the newest finished run. Cards sort newest first. A card is collapsed unless a run is running or queued, and clicking the header toggles it. Expanded, it lists each branch pill and its run rows, both newest first. A missing repository shows one line of secondary text and cannot expand.

### Run row
State glyph (13px), workflow name, PR number as `#123` (`!12` for a GitLab merge request), the starter's avatar (16px), the run title and a trailing time. A running row shows queue-to-completion elapsed time in amber and remaining time in secondary. Remaining time is prefixed with `~`; when its history is exhausted, the row shows `Taking longer`. The progress bar fills at a constant rate with no visible steps. Clicking a row opens the run on GitHub or GitLab and closes the panel.

### Notice card
A 64px glass card tinted orange, with a 20px glyph and up to two lines of callout text. The signed-out notice carries a prominent Retry button.

### Menu bar strip
The status item is always visible. Each repository with a running, overdue or queued run gets one 15px glyph, 5px apart. Passed and failed repositories get no glyph, so failures show only in the panel. With nothing running or queued, the item shows an 18px monochrome template ring, open by a quarter with round caps, matching the app icon. When signed out, the item is a single red lock.

### Toast
A glass card like a panel card, 340px wide and sized to its content, with a state glyph the size of the card header's, `owner/name` in the header style and one secondary line such as `CI failed on main`, with the PR number trailing as `#123` (`!12` for GitLab). Toasts appear 1pt below the menu bar, placed like the panel, newest on top, 8px apart, at most three. Each fades after 6 seconds unless the pointer rests on it. Clicking one opens the run on GitHub or GitLab. No toast shows while the panel is open.

### State glyphs
Passed is a filled check circle, failed a filled cross circle, queued a clock. Running is an amber ring with a pie that fills with estimated progress, or a center dot when there is no estimate. Overdue is a full orange pie.

### Panel behavior
The panel opens after the pointer rests 140ms on the menu bar icon and closes 50ms after the pointer leaves both icon and panel. A click on the icon and the global shortcut toggle it. The shortcut is Ctrl+Opt+Cmd+G by default and can be changed in Settings. A right click or Ctrl-click on the icon opens a menu with Settings…, Check for updates…, Refresh now, Send feedback… and Quit Peek, and closes the panel. Escape and a click outside close it.

### App icon
A flat green open ring on a solid dark squircle. It has no glass, no shadow, no translucency and no specular highlight.

## Do's and Don'ts

### Do:
- **Do** use one regular-glass card per repository with 22px corners.
- **Do** keep every color tied to a run state.
- **Do** use monospaced digits for times and counts.
- **Do** write UI copy in sentence case with plain words, and say each piece of information once.

### Don't:
- **Don't** add a header, footer or subheading to the panel.
- **Don't** add gradients, gloss or shadows, in the panel or the icon.
- **Don't** support a light appearance.
- **Don't** use em dashes or middle dot or bullet separators in UI text.
- **Don't** show a menu bar glyph for a repository with no running or queued run.
