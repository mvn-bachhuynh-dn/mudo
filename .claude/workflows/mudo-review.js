export const meta = {
  name: 'mudo-review',
  description: 'Whole-branch review of MuDo changes across Go, Swift, tests and public-repo safety, with adversarial verification',
  whenToUse: 'Before merging a feature branch or pushing to GitHub. args: base ref (default "origin/main")',
  phases: [
    { title: 'Review', detail: '4 dimensions over BASE..HEAD' },
    { title: 'Verify', detail: 'skeptic per dimension refutes each finding' },
  ],
}

// args: "origin/main" | "<sha>" (default origin/main)
const BASE = (typeof args === 'string' && args) || (args && args.base) || 'origin/main'

const CTX = `Project: MuDo (server/: Go daemon mudod; app/: Swift macOS widget). Review the changes in \`git diff ${BASE}...HEAD\` (see also \`git log ${BASE}..HEAD\`), reading surrounding code as needed. Do NOT edit files. Report only real defects with file:line and a concrete failure scenario.`

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'important', 'minor'] },
          file: { type: 'string', description: 'path:line' },
          problem: { type: 'string' },
          scenario: { type: 'string', description: 'inputs/state that trigger the wrong behaviour' },
          fix: { type: 'string' },
        },
        required: ['id', 'severity', 'file', 'problem', 'scenario', 'fix'],
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
        properties: { id: { type: 'string' }, real: { type: 'boolean' }, reason: { type: 'string' } },
        required: ['id', 'real', 'reason'],
      },
    },
  },
  required: ['verdicts'],
}

const DIMENSIONS = [
  { key: 'go', prompt: 'Dimension: Go correctness in server/ (concurrency, error paths, build tags per GOOS, file permissions, idempotent install/uninstall, hook never failing or printing to stdout).' },
  { key: 'swift', prompt: 'Dimension: Swift correctness in app/ (Swift 6 concurrency/actor isolation, main-thread UI, AppleScript/Process calls off the main thread, Keychain, focus fallbacks never opening new windows).' },
  { key: 'tests', prompt: 'Dimension: tests. Changed behaviour without a test that would fail without it; tests touching the real $HOME, ~/.claude, ~/.kiro, ~/.config, launchctl or systemctl; assertions that assert nothing.' },
  { key: 'public', prompt: 'Dimension: public-repo safety and security. Real hostnames, IPs, tokens, emails or internal domains in code, tests, docs or commit messages (`git log -p ' + BASE + '..HEAD`); command or AppleScript injection through network-supplied fields; secrets in logs.' },
]

const results = await pipeline(
  DIMENSIONS,
  d => agent(`${CTX}\n\n${d.prompt}`, { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS }),
  (rev, d) => {
    const fs = (rev && rev.findings) || []
    if (!fs.length) return { dimension: d.key, confirmed: [], rejected: [] }
    return agent(`${CTX}\n\nYou are a skeptic. For EACH finding below (dimension: ${d.key}), read the code and try to REFUTE it: does the scenario really happen? real=false when wrong, unreachable or speculative.\n\n${JSON.stringify(fs, null, 2)}`,
      { label: `verify:${d.key}`, phase: 'Verify', schema: VERDICTS })
      .then(v => {
        const byId = new Map(((v && v.verdicts) || []).map(x => [x.id, x]))
        return {
          dimension: d.key,
          confirmed: fs.filter(f => byId.get(f.id) && byId.get(f.id).real),
          rejected: fs.filter(f => !(byId.get(f.id) && byId.get(f.id).real)).map(f => ({ id: f.id, reason: byId.get(f.id) ? byId.get(f.id).reason : 'no verdict' })),
        }
      })
  },
)

const out = results.filter(Boolean)
log(out.map(r => `${r.dimension}: ${r.confirmed.length} confirmed, ${r.rejected.length} rejected`).join('; '))
return out
