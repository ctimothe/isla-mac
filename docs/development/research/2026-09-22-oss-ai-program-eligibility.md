# Open-source AI maintainer programs: Isla eligibility research

**Checked:** 2026-09-22 (Asia/Tashkent)  
**Repository checked:** <https://github.com/ctimothe/isla-mac>  
**Scope:** Anthropic's Claude for Open Source and OpenAI's Codex for Open Source. Official pages are the authority; X reports below are anecdotes only.

## Bottom line for Isla

Isla is technically eligible to submit an OpenAI application, but its public evidence currently supports a **low probability of acceptance**. Anthropic is stricter: the project does not meet a published Maintainer Track threshold, and the applicant's public GitHub bio currently says “17 years old.” If that is accurate, Anthropic's 18-or-age-of-majority rule makes the applicant ineligible today regardless of project merit.

- The public repository is MIT-licensed, public, and actively maintained: GitHub shows the `dynamic-island-parity` branch, 369 commits, and the latest public activity on 2026-09-21. The README describes a macOS 15+ Swift app distributed as open source. ([repository](https://github.com/ctimothe/isla-mac), [MIT license](https://github.com/ctimothe/isla-mac/blob/dynamic-island-parity/LICENSE))
- Public adoption is currently small: 8 stars, 0 forks, no issues, 12 merged pull requests (all authored by the maintainer), and 5 total downloads across the two GitHub release DMGs. There is no public signal of package-registry downloads or downstream dependents. ([repository metrics](https://github.com/ctimothe/isla-mac), [releases](https://github.com/ctimothe/isla-mac/releases))
- Repository quality is stronger than adoption: the public branch has 369 commits, an MIT license, a full `./scripts/check` release gate, and recent successful GitHub Actions runs. GitHub's community profile is only 42%, however, because standard contribution/community files and templates are missing. ([Actions](https://github.com/ctimothe/isla-mac/actions), [repository](https://github.com/ctimothe/isla-mac))
- Account-wide PR volume does not rescue the Anthropic application. GitHub's authenticated search finds 192 merged PRs in the last 12 months, but 178 are in private repositories and the remaining 14 are in `ctimothe`-owned public repositories. Anthropic's criterion requires 100 merged PRs into **public repositories the applicant does not own**.
- The local parity worktree has recent commits through 2026-09-14, but the application should describe only work already public on GitHub. Unpushed local commits do not establish public activity or adoption.
- The strongest gap is ecosystem scale: Isla is a standalone macOS application, not a package/library with a dependency graph, registry downloads, or a large external contributor base. Do not claim thresholds that cannot be evidenced.

**Practical recommendation:** apply to OpenAI now if desired, but expect low odds and use only verified evidence. For Anthropic, wait until the applicant meets the age rule and at least one objective Maintainer Track threshold, or until Isla has a genuinely strong Ecosystem Impact case. Do not present Isla as meeting Anthropic's numeric thresholds today.

## Anthropic: Claude for Open Source

### Official program and benefit

Anthropic advertises six months of free Claude Max 20x for approved open-source contributors. The landing page lists maintainers/library authors, core contributors, active contributors, community builders, and critical infrastructure maintainers. ([program page](https://claude.com/contact-sales/claude-for-oss))

The binding terms say the benefit is a complimentary Claude Max 20x subscription for six months, with a stated cap of 10,000 approved recipients unless Anthropic increases it. Anthropic may close, pause, or change the program at any time. The subscription is personal, non-transferable, and overages may still be charged. ([terms §§1, 4, 6](https://www.anthropic.com/claude-for-oss-terms))

### Eligibility rules that matter

Applicants need at least one Maintainer Track signal or may apply under the discretionary Ecosystem Impact Track, plus all general requirements. The official terms specify:

- Maintainer Track: at least 500 dependent repositories, 100 dependent packages, or 200,000 monthly package downloads; listed committer/maintainer of a recognized foundation or language project; 100 merged PRs into repositories the applicant does not own during the prior 12 months; 20 external contributors with merged PRs in a maintained repository during the prior 12 months; or OpenSSF criticality score ≥0.4.
- Ecosystem Impact Track: a project the ecosystem meaningfully depends on, such as widely used infrastructure, developer tooling, or foundational packages. Anthropic evaluates downstream dependents, breadth, criticality, and the applicant's role.
- General requirements: natural person; at least 18 or age of majority; legal residence where Claude is available and no export/sanctions restriction; GitHub account in good standing at least two years old; public OSS activity within the preceding 90 days; and contribution to at least one project under an OSI-approved license.
- Application fields: GitHub sign-in, email, brief intended-use description, and a qualification explanation of no more than 500 words. Applications are rolling; Anthropic says it contacts approved applicants only. Activation links expire after 90 days.

Sources: [Anthropic terms §§2–3](https://www.anthropic.com/claude-for-oss-terms), [program page](https://claude.com/contact-sales/claude-for-oss), [supported locations](https://support.claude.com/en/articles/8461763-where-can-i-access-claude).

### Isla against Anthropic's criteria

| Criterion | Evidence for Isla | Assessment |
|---|---|---|
| OSI license | MIT `LICENSE` | Meets |
| Public activity in last 90 days | Public branch latest commit 2026-09-21 | Meets, assuming applicant's GitHub account is the maintainer account |
| GitHub account ≥2 years | `ctimothe` created 2022-11-29 | Meets |
| Natural person aged 18 / age of majority | Public bio currently says “17 years old” | Does not meet if the bio is accurate |
| 500 dependent repos / 100 packages | Standalone app; no evidence | Not shown |
| 200,000 monthly downloads | No package registry distribution | Not shown |
| 100 merged PRs to public repos not owned | 192 merged PRs found account-wide; 178 are private, 14 are in `ctimothe`-owned public repos | Does not meet on public evidence |
| 20 external merged contributors | GitHub page shows no PR activity; no evidence of 20 | Not shown |
| OpenSSF criticality ≥0.4 | No score found | Unknown; do not claim |
| Ecosystem Impact Track | Useful Mac utility, but 8 stars and no visible adoption signals | Possible to explain, weak evidence today |
| Location | Uzbekistan appears on Anthropic's supported list | Meets location condition, subject to current terms |

The project therefore lacks an Anthropic qualifying track on current public evidence. If the GitHub age bio is accurate, the general age rule is an independent hard block. After reaching the required age, the applicant could use the Ecosystem Impact Track only if they can document real users or downstream impact. Acceptance is discretionary even when a threshold is met.

## OpenAI: Codex for Open Source

### Official program and benefit

OpenAI's current program is **Codex for Open Source**. Selected maintainers receive six months of ChatGPT Pro (including Codex), possible API credits for maintainer workflows, and conditional access to Codex Security. ([application form](https://openai.com/form/codex-for-oss/), [developer program page](https://developers.openai.com/community/codex-for-oss))

The form asks for first/last name, ChatGPT-account email, public GitHub username, public repository URL, maintainer role (primary or core), why the repository qualifies (maximum 500 characters, including stars/downloads/ecosystem importance), whether the applicant wants Codex Security and/or API credits, an OpenAI Organization ID, intended API-credit use (maximum 500 characters), and anything else (maximum 500 characters). Applications are rolling and selected applicants are notified by email. ([form fields](https://openai.com/form/codex-for-oss/))

The program terms are intentionally discretionary: applicants need a valid ChatGPT account and accurate repository/role information; OpenAI considers repository usage, ecosystem importance, active maintenance, role/permissions, and capacity. Benefits can vary, may be limited-duration, and are personal and non-transferable. API credits and Codex Security can require separate review and proof of repository control. ([terms §§1–5](https://learn.chatgpt.com/docs/codex-for-oss-terms))

OpenAI also documents a separate **Codex open-source fund**: up to $25,000 in API credits per grant, rolling applications, from a $1 million initiative supporting projects that use Codex CLI or other OpenAI models. This is not the same as the six-month Pro benefit and should be treated as a separate funding route. ([fund documentation](https://github.com/openai/codex/blob/main/docs/open-source-fund.md))

### Isla against OpenAI's criteria

Isla meets the basic “active public OSS project / primary maintainer can apply” shape and has a clear maintainer use case: code review, release checks, issue triage, localization, and macOS-specific maintenance. However, the public repository currently shows only 8 stars, no forks or issues, 12 maintainer-authored merged pull requests, and 5 release-asset downloads, so the form's “meaningful usage, broad adoption, or clear importance” case is weak without additional evidence. ([OpenAI program page](https://developers.openai.com/community/codex-for-oss), [repository](https://github.com/ctimothe/isla-mac))

OpenAI lists Uzbekistan as a supported ChatGPT country. ([supported countries](https://help.openai.com/en/articles/7947663-chatgpt-supported-countries))

## What X recipients report (anecdotal, not eligibility proof)

Search results and mirrors of X posts show that the benefits are real for some selected applicants, but they do not establish a reliable acceptance threshold. Mirrors can be stale, edited, or incomplete; verify any post on X itself before relying on it.

### Claude

- **Daniel San, `@dani_avila7`**: a mirror reproduces his first-person post, “I got selected for the Claude for Open Source Program again!”, saying this was the second support period for maintaining `aitmpl.com` / `davila7/claude…`. The post is a credible recipient signal because it names the project and describes repeat support, but the mirror does not expose a canonical X status URL or a screenshot of the grant. ([X-profile mirror](https://www6.twstalker.com/dani_avila7), [alternate mirror](https://www.sotwe.com/dani_avila7?lang=id))
- **Stephane Fourdrinier, `@SFourdrinier`**: an X mirror shows Lydia Hallie replying that she would ensure he received another six months of Claude for OSS while he maintained an Apache-2.0 GitHub project. This is useful evidence of renewal being possible, but it is a mirror and does not prove the project met a published numeric threshold. ([mirror of status](https://zamantika.com/de/SFourdrinier/status/2096110302777733502))
- **Pattern:** recipient posts commonly emphasize active maintenance and ecosystem impact, not merely creating a new repository. Daniel San's public portfolio includes `claude-code-templates`, currently above 30,000 stars and 3,500 forks. A separate first-person write-up from Chánh Đại reports acceptance with a 2,000-star portfolio project plus a React package with 30,000+ weekly downloads; it is not an X source, so treat it only as corroboration. ([Daniel San's project](https://github.com/davila7/claude-code-templates), [Chánh Đại's write-up](https://dai.is-a.dev/blog/joining-claude-for-open-source-program))

### OpenAI

- **Tinkle, `@aiTinkle`**: a TwStalker mirror translates a first-person post as “I just applied, and was approved the same day,” and says the benefit was six months of ChatGPT Pro + Codex + API credits. The project is not clearly identified in the mirror, so it shows possible fast approval, not a project-comparable precedent. ([mirror/status](https://w.twstalker.com/Web3Tinkle/status/2031946833480860147))
- **Tibo, `@thsottiaux`**: a mirror of an X post advertises six months of Pro and free Codex Security and says another batch would go out the following Wednesday. This is program promotion, not recipient evidence. ([mirror/status](https://www.twstalker.com/tobihagemann/status/2042337023734780414))
- No independently verifiable first-person X post was found that both identifies a comparable small desktop application and proves OpenAI acceptance. A verifiable accepted maintainer outside X maintains Super Productivity, currently above 22,000 stars and 2,000 forks; that is useful context but not a comparable precedent for Isla. ([acceptance report](https://community.openai.com/t/codex-for-oss-activation-link-rejects-accepted-maintainers-who-already-subscribe/1393080), [project](https://github.com/super-productivity/super-productivity))

## Application advice for this repository

1. Apply to OpenAI against the public `ctimothe/isla-mac` repository, not an unpushed worktree branch.
2. Before applying, add a product screenshot/demo, homepage, GitHub topics, `CONTRIBUTING.md`, issue/PR templates, and a small set of real issues. These improve inspectability; they do not substitute for adoption.
3. Use a short evidence pack: public commit dates, release links/download counts, MIT license, successful CI/release gates, and a precise description of how Codex would reduce maintainer load.
4. Do not claim package downloads, dependents, external contributors, OpenSSF score, clone traffic, or user counts unless you can attach public evidence. Current clone traffic is dominated by CI activity and is not a credible adoption metric.
5. For Anthropic, do not apply while under the age threshold. After that, apply only when an objective Maintainer Track threshold is met or a documented ecosystem-impact case exists.
6. For OpenAI, submitting now is reasonable because its terms publish no hard star threshold, but the current adoption case remains weak.
7. Treat “free” as a limited personal subscription. Anthropic's terms allow overage charges; both programs can revoke or change benefits, and neither promises acceptance.
