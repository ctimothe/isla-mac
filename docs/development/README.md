# Development notes

This folder records how Isla was designed, planned, tested and checked. You
don't need any of it to use Isla. It's here for contributors who want to know
why something works the way it does.

Most files are dated and describe the project as it was on that day. The
design document and its dated amendments always win; otherwise, when two files
disagree, the newer one is right.

Some audits cite raw JSON ledgers and long research digests. Those were
removed from the tree to keep it readable; they are still in the git history.

| Where | What it holds |
| --- | --- |
| [plans/2026-08-18-dynamic-island-parity-design.md](plans/2026-08-18-dynamic-island-parity-design.md) | The design Isla is built to. Changes are added as dated amendments, never rewritten. |
| [checklist.md](checklist.md) | What each release finished, what Isla deliberately does differently from Cyclop, and the checks still owed on real hardware. |
| [plans/](plans/) | Plans for each piece of work, before it was built. |
| [specs/](specs/) | Feature designs. `shell-music-mvp.md` describes an earlier prototype, not this app. |
| [audits/](audits/) | Reviews of the whole app and the bugs they found. |
| [research/](research/) | Background reading: Apple's own players, other notch apps, technical limits. |
| [performance/](performance/) | CPU and memory measured against Cyclop 0.6.5. |
| [verification/](verification/) | Results of release-candidate checks. |

How to verify and ship a release is in [../runbook.md](../runbook.md) and
[../release-checklist.md](../release-checklist.md).
