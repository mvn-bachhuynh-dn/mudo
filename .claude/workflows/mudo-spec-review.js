export const meta = {
  name: 'mudo-spec-review',
  description: 'Review a MuDo design spec through 4 lenses, then have a skeptic try to refute each lens\'s findings',
  whenToUse: 'After writing or changing a spec in docs/superpowers/specs/, before writing the plan. args: spec path',
  phases: [
    { title: 'Review', detail: 'macOS feasibility, codebase fit, edge cases, security' },
    { title: 'Verify', detail: 'one skeptic per lens tries to refute each finding' },
  ],
}

// args: "docs/superpowers/specs/<file>.md" (or { spec: "..." })
const SPEC = typeof args === 'string' ? args : args && args.spec
if (!SPEC) throw new Error('pass the spec path as args, e.g. "docs/superpowers/specs/2026-10-17-mudo-local-ssh-design.md"')

const CTX = `Project: MuDo = Go daemon "mudod" (server/) that receives Claude Code / Kiro CLI hooks and streams sessions over SSE, plus a Swift macOS widget (app/: MuDoCore library + MuDo executable). Earlier design: docs/superpowers/specs/2026-10-14-mudo-design.md.
Spec under review: ${SPEC}. Read it fully first.
Do NOT edit files. Report only concrete problems that would make the implementation wrong, fail or need rework, not style nits. Each finding cites the spec section and evidence (file:line, command output or URL).`

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'short slug' },
          section: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'important', 'minor'] },
          problem: { type: 'string' },
          evidence: { type: 'string' },
          fix: { type: 'string', description: 'concrete change to the spec' },
        },
        required: ['id', 'section', 'severity', 'problem', 'evidence', 'fix'],
      },
    },
  },
  required: ['findings'],
}

const VERDICTS = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          real: { type: 'boolean' },
          reason: { type: 'string' },
          adjusted_fix: { type: 'string', description: 'better fix if the proposed one is wrong or too heavy; empty otherwise' },
        },
        required: ['id', 'real', 'reason', 'adjusted_fix'],
      },
    },
  },
  required: ['verdicts'],
}

const LENSES = [
  { key: 'platform', prompt: 'Lens: platform feasibility. Check every OS mechanism the spec relies on works as described (syscalls and their Go bindings in the module cache, CLI output formats of ps/lsof/launchctl/systemctl/tmux, AppleScript dictionaries of the apps it scripts, macOS permissions, code signing). Use `go env GOMODCACHE` sources and web search/fetch for official docs.' },
  { key: 'codebase', prompt: 'Lens: fit with existing code. Read the server/internal packages, server/cmd/mudod, app/Sources/MuDoCore, app/Sources/MuDo and both Makefiles. Find where the spec contradicts existing interfaces, misses a file that must change, breaks existing behaviour or tests, or assumes something the code does not provide.' },
  { key: 'edges', prompt: 'Lens: edge cases. Stress-test the spec\'s decision rules and fallbacks: stale or missing data, several candidates matching, sessions from older versions, network paths that rewrite addresses, nested or multiplexed terminals, wrong rule ordering. Propose the simplest correct rule for each real gap.' },
  { key: 'security', prompt: 'Lens: security and privacy. The repo is PUBLIC on GitHub. Check that no real hostnames, IPs, tokens or emails would land in code, tests or docs; daemon binding and token auth; shell/AppleScript injection through any field that comes from the network or from other processes; installers writing to user config; logs leaking prompts. Each finding names the exact path or exposure.' },
]

const results = await pipeline(
  LENSES,
  l => agent(`${CTX}\n\n${l.prompt}`, { label: `review:${l.key}`, phase: 'Review', schema: FINDINGS }),
  (rev, l) => {
    const fs = (rev && rev.findings) || []
    if (!fs.length) return { lens: l.key, confirmed: [], rejected: [] }
    return agent(`${CTX}\n\nYou are a skeptic. A reviewer (lens: ${l.key}) reported the findings below. For EACH, check the spec, the code and if needed external docs, and try to REFUTE it. real=false when it is wrong, already handled by the spec, or speculative. If real but the fix is wrong or heavier than needed, give adjusted_fix.\n\nFindings:\n${JSON.stringify(fs, null, 2)}`,
      { label: `verify:${l.key}`, phase: 'Verify', schema: VERDICTS })
      .then(v => {
        const byId = new Map(((v && v.verdicts) || []).map(x => [x.id, x]))
        const confirmed = [], rejected = []
        for (const f of fs) {
          const vd = byId.get(f.id)
          if (vd && vd.real) confirmed.push({ ...f, fix: vd.adjusted_fix || f.fix, verify_note: vd.reason })
          else rejected.push({ id: f.id, problem: f.problem, reason: vd ? vd.reason : 'no verdict' })
        }
        return { lens: l.key, confirmed, rejected }
      })
  },
)

const out = results.filter(Boolean)
log(out.map(r => `${r.lens}: ${r.confirmed.length} confirmed, ${r.rejected.length} rejected`).join('; '))
return out
