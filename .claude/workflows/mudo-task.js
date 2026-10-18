export const meta = {
  name: 'mudo-task',
  description: 'Implement one task of a MuDo plan, review it (spec + quality), and run up to 3 fix rounds',
  whenToUse: 'Executing a plan in docs/superpowers/plans/ one task at a time. args: { plan, task }',
  phases: [
    { title: 'Implement', detail: 'TDD, run tests, commit' },
    { title: 'Review', detail: 'spec compliance + code quality on BASE..HEAD' },
    { title: 'Fix', detail: 'up to 3 fix + re-review rounds' },
  ],
}

// args: { plan: "docs/superpowers/plans/<file>.md", task: 3 }
const PLAN = args && args.plan
const TASK = args && args.task
if (!PLAN || !TASK) throw new Error('pass args { plan: "<plan path>", task: <number> }')

const RULES = `Project rules (binding):
- Read ONLY "Task ${TASK}" of ${PLAN} plus its "Global Constraints" section; that text is your requirements, exact values verbatim.
- Tests never touch the real $HOME, ~/.claude, ~/.kiro, ~/.config, launchctl or systemctl; use temp dirs and injected fakes.
- Never run \`mudod install\`/\`uninstall\` for real.
- The repo is PUBLIC: never write real hostnames, IPs, tokens or emails. Use placeholders (devbox, 100.64.0.10, fd7a:115c:a1e0::10, code.example.com, user@).
- Go tests: \`cd server && go test ./...\` (also \`GOOS=darwin go vet ./...\` when darwin files change).
- Swift tests run on the build Mac: \`MUDO_MAC=mudo-mac app/scripts/on-mac swift test\` (needs network, no sandbox). If the Mac is unreachable (check first with \`ssh -o ConnectTimeout=8 mudo-mac true\`), run MuDoCore tests with \`app/scripts/docker-test\` (Linux, Docker, no sandbox) and say in your report that the macOS-only MuDo target was NOT compiled; in that case write AppKit code with extra care (Swift 6 strict concurrency, @MainActor, Sendable) since nothing compiles it.
- Match the surrounding code's style and comment density. Commit with a conventional message ending in "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>".`

const IMPL = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['DONE', 'DONE_WITH_CONCERNS', 'BLOCKED'] },
    base: { type: 'string', description: 'git rev-parse HEAD before any change' },
    head: { type: 'string', description: 'git rev-parse HEAD after the last commit' },
    tests: { type: 'string', description: 'one line: which suites ran and their counts' },
    concerns: { type: 'string' },
  },
  required: ['status', 'base', 'head', 'tests', 'concerns'],
}

const REVIEW = {
  type: 'object',
  properties: {
    spec_ok: { type: 'boolean' },
    issues: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['critical', 'important', 'minor'] },
          file: { type: 'string', description: 'path:line' },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'file', 'problem', 'fix'],
      },
    },
  },
  required: ['spec_ok', 'issues'],
}

const FIX = {
  type: 'object',
  properties: {
    head: { type: 'string' },
    tests: { type: 'string' },
    notes: { type: 'string', description: 'per issue: fixed, or why not' },
  },
  required: ['head', 'tests', 'notes'],
}

phase('Implement')
const impl = await agent(`${RULES}\n\nImplement Task ${TASK} of ${PLAN} with TDD: record BASE first, write failing tests, implement, run the relevant test suites, commit. If blocked, stop and report BLOCKED with the reason in concerns.`,
  { label: `implement:task-${TASK}`, schema: IMPL })
if (!impl || impl.status === 'BLOCKED') return { task: TASK, status: 'BLOCKED', impl }

const review = (head, round) => agent(`${RULES}\n\nYou are the task reviewer, independent from the implementer. Review \`git diff ${impl.base}..${head}\` (and \`git log ${impl.base}..${head}\`) against Task ${TASK}.
1. Spec compliance: every requirement of the task is met, nothing extra was built.
2. Quality: correctness, tests that would fail without the change, no test touching real user dirs, no real infra identifiers, style matching the surrounding code.
Do not re-run test suites the implementer ran (${impl.tests}); read the code. Report only real issues.`,
  { label: `review:task-${TASK}:r${round}`, phase: round ? 'Fix' : 'Review', schema: REVIEW })

const blocking = r => !r || !r.spec_ok || r.issues.some(i => i.severity !== 'minor')

phase('Review')
let head = impl.head
let rev = await review(head, 0)
const rounds = []
for (let round = 1; round <= 3 && blocking(rev); round++) {
  phase('Fix')
  const open = rev ? rev.issues.filter(i => i.severity !== 'minor') : []
  const fix = await agent(`${RULES}\n\nFix round ${round} for Task ${TASK}. The reviewer reported:\nspec_ok=${rev && rev.spec_ok}\n${JSON.stringify(open, null, 2)}\nFix each issue (or explain why it is wrong), re-run the affected tests, commit.`,
    { label: `fix:task-${TASK}:r${round}`, schema: FIX })
  if (!fix) break
  head = fix.head
  rounds.push(fix)
  rev = await review(head, round)
}

const minors = rev ? rev.issues.filter(i => i.severity === 'minor') : []
log(`task ${TASK}: ${blocking(rev) ? 'OPEN ISSUES after fix rounds' : 'approved'}, ${rounds.length} fix round(s), ${minors.length} minor deferred`)
return {
  task: TASK,
  status: blocking(rev) ? 'NEEDS_HUMAN' : 'APPROVED',
  base: impl.base,
  head,
  tests: rounds.length ? rounds[rounds.length - 1].tests : impl.tests,
  concerns: impl.concerns,
  open_issues: rev ? rev.issues.filter(i => i.severity !== 'minor') : [],
  minor_deferred: minors,
}
