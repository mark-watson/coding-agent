# IMPROVEMENTS.md — Porting `racket-coding-agent` features into `coding-agent.el`

Notes from studying `../racket-coding-agent` (the Racket CLI agent) against the
current `coding-agent.el`. The two agents have different shapes: the Emacs agent
is a *single-shot* edit/review tool ("send file(s), get edits, review diff,
apply"), while the Racket agent is a *multi-turn agentic REPL* with tool use
(`read_file`, `list_dir`, `grep`, `run_shell`, `propose_edit`), conversation
history, skills, web search, and a JSON config system. Below are the most useful
Racket features, ordered roughly by value-to-effort, with concrete notes on how
each would map onto the elisp code.

## 1. Agentic tool use (the big one)

The Racket agent's core design difference: instead of stuffing whole files into
the prompt and asking for edited output, the model *drives the session* with
tools (`tools.rkt`):

- `read_file`, `list_dir`, `grep` — the model explores the codebase itself
  (`SYSTEM-PROMPT-TEMPLATE` explicitly requires reading before editing).
- `propose_edit path old new` — model proposes a full-file replacement, gated on
  a *stale-base check*: if the on-disk file doesn't match the `old` the model
  provided, the edit is rejected with "read the file again and retry". This
  eliminates an entire class of silent corruption that the elisp
  search/replace-block parser can't catch.
- `run_shell` — whitelist-gated shell (`make`, `ls`, `pwd`, `cat`, `uv` only).
- `make check` gate — after every applied edit, `make check` runs and its
  output (truncated to 2000 chars) is fed back to the model as a tool result,
  so the agent can fix what it broke.

**Emacs mapping:** gptel supports tool calling (`:tools` argument to
`gptel-request`, and `gptel-make-tool`). A `coding-agent--tools` registry in
elisp with five tools mirroring the Racket ones, plus an agentic loop
(`coding-agent-agent-run`) that keeps calling the model until it stops issuing
tool calls, would be the single biggest capability upgrade. The existing
`*coding-agent-diff*` review machinery can be reused inside an elisp
`propose_edit` handler.

## 2. Post-edit test gate (`make check`)

Even without full tool use: after `coding-agent--apply-text` runs, optionally
run `make check` (or a user-configurable command, e.g. a new defcustom
`coding-agent-check-command`) in the project root and show the result in an
echo area / `*coding-agent-check*` buffer, offering revert on failure
(`approval.rkt`/`tools.rkt` pattern). The elisp agent already has the revert
plumbing (`coding-agent--check-and-maybe-revert`); hooking a subprocess check
into the same confirm path is a small change with a large safety payoff.

## 3. y/n/skip with feedback (`prompt-yes-no-skip`)

The Racket approval prompt has three answers: yes / no / **skip with a reason**,
and the reason is fed back to the model as a tool result ("user skipped: <reason>"),
so the agent adjusts instead of retrying blindly. The elisp review only asks a
plain `y-or-n-p`. Add a third option to `coding-agent--review` ("skip & tell the
model why"), capture one line of text, and stash it so the next
`coding-agent-refine` call prepends it to the instruction. This is nearly free
to implement and noticeably improves the refine loop.

## 4. Explicit dry-run and auto-approve modes

Racket has `--dry-run` (show diffs, never write) and `-y/--yes` (auto-approve,
still showing the diff) as first-class parameters. In elisp these would be two
defcustoms / interactive toggles:

- `coding-agent-dry-run` — `coding-agent--apply-text` becomes display-only.
  Very useful with `coding-agent-run-project` for "what would it do?" runs.
- `coding-agent-auto-approve` — skip the `y-or-n-p` in `coding-agent--review`;
  keep the diff buffer up for inspection. Combine with the `make check` gate
  (#2) to stay safe.

## 5. Conversation history + `/context`, `/compact`, `/history`

The elisp agent is stateless across runs (only `coding-agent--proposed-text`
survives, for refine). The Racket agent keeps a full message list and offers:

- `/context` — a table of messages with char counts and previews
  (`show-context`, `message-char-size`, `wrap-preview`) and an estimated token
  count (`chars / 4`). This is how the user knows when the session is about to
  blow the context window.
- `/compact` — a dedicated LLM call (`COMPACT-SYSTEM-PROMPT`) that summarizes
  the transcript; the message list is then replaced by
  `[original system prompt, summary user-message]`. Cheap and very effective for
  long sessions.
- `/reset`, `/history`.

**Emacs mapping:** keep a buffer-local `coding-agent--messages` list; add
`coding-agent-show-context` (an ` Org`-style or `tabulated-list-mode` buffer),
`coding-agent-compact` (one extra `gptel-request` with the compactor prompt),
and have `coding-agent-run`/`refine` append to the history so follow-ups have
context. This also fixes a real limitation: today, refine only sees the *last
proposal*, not why earlier edits were made.

## 6. Skills (`~/.agents/skills/<name>/SKILL.md`)

The Racket agent loads skill files by name: any `/foo` that isn't a built-in
command is looked up as `~/.agents/skills/foo/SKILL.md`, parsed for a
`description:` frontmatter line, and injected as a system message
("use it as authoritative reference…"). `/skills` lists them.

**Emacs mapping:** this is almost trivially portable —
`coding-agent--list-skills` (directory-files + SKILL.md test),
`coding-agent--skill-description` (parse the `---` frontmatter with a regex),
and `coding-agent-load-skill` (interactive, `completing-read` over skills), which
inserts the skill content into the prompt prefix (or conversation system
message if #5 lands). Since both agents would share `~/.agents/skills`, this
unifies your two toolchains.

## 7. Stuck-loop and malformed-tool-call detection

`chat-loop.rkt` tracks signatures of the last N tool-call batches
(`call-signature`, `seen-too-often?`, `REPEAT-WINDOW` 5 / `REPEAT-LIMIT` 2) and
halts with an explanatory message instead of burning all iterations. And
`execute-tool-calls` in `tools.rkt` converts *every* failure mode — invalid
JSON args, non-object args, missing required args, truncated calls with no
function name, unknown tool — into a *textual error fed back to the model*
rather than an exception. Both patterns matter with weaker local models and are
worth copying into any elisp tool-calling loop (#1).

## 8. Hierarchical JSON provider config (`harness-config.rkt`)

The Racket agent merges `~/.coding_harness.json` with
`.local_coding_harness.json` (deep merge, project-local wins) into
named provider *profiles*: `{type, endpoint, api_key_env, model, generation
{temperature, max_tokens}}`, with a `default_provider` key and runtime
`/provider <name>` switching. The elisp agent hard-codes three providers in
`coding-agent--providers` and per-provider defcustoms.

**Emacs mapping:** add `coding-agent-config-files` (global + project-local) read
with Emacs 29's native `json-parse-string` / `json-read-file`, converted into
plists in the same shape as `coding-agent--providers` entries. This would let
users define arbitrary OpenAI-compatible endpoints (MLX server, remote Ollama
shims, vLLM, etc.) without writing elisp, and give per-project provider/model
pins — e.g. this repo could carry a `.coding-agent.json` defaulting to the
local MLX gemma model.

## 9. Web search integration (Brave / Exa) and intent classification

`search.rkt` implements 5-result Brave and Exa search (one `GET`, one `POST`,
small response shapes). `agent.rkt` routes each user line through
`classify-intent` (heuristic keyword lists first, a 10-token LLM fallback
second) into general/coding/hybrid, and prepends formatted search results for
general/hybrid queries (`maybe-search`).

Parts that make sense in Emacs:

- `coding-agent-search-toggle` / `coding-agent-search-engine` defcustoms plus a
  small `url-retrieve`- or `plz`-based Brave/Exa client, injecting results into
  the prompt for "research-y" instructions (e.g. "upgrade this to the current
  X library API").
- The intent classifier is probably overkill for the elisp agent's explicit,
  instruction-per-call workflow — but a `/search`-style toggle that simply
  enriches the next instruction with web results would still help with
  library-doc questions.

## 10. Token/session accounting

`fireworks-ai.rkt` and `mlx-serve.rkt` accumulate `prompt_tokens` /
`completion_tokens` from every response and `/tokens` prints usage plus an
estimated dollar cost (Fireworks price constants; $0 for local). gptel can
surface `:usage` info; recording it in the elisp agent and adding
`coding-agent-session-usage` would make expensive Anthropic runs much less
mysterious.

## 11. Small robustness details worth stealing

- **Hidden-file refusal** (`hidden-file?`): Racket tools refuse to read or list
  `*~`, `#*#`, and dotfiles. The elisp agent filters secrets for *project*
  sends, but `coding-agent-run` on an open `.env` buffer sends it happily —
  add the same name test to `coding-agent-run`.
- **Stuck busy-flag healing**: the elisp agent already has
  `coding-agent-reset`; the Racket equivalent is that tool errors always return
  strings, never throw — worth keeping as a design rule for #1.
- **Truncated `make check` output** (`MAX-CHECK-OUTPUT-CHARS`): whatever check
  command is added, cap captured output before showing/feeding it back.
- **`no-op edit detection`**: `propose_edit` reports "no changes (proposed
  content matches current file)" instead of writing. `coding-agent--apply-text`
  could short-circuit the same way to avoid pointless backups/buffer churn.

## Suggested order

1. `make check` gate after apply + auto-approve/dry-run toggles (pure additions
   to existing flow; big safety/convenience win).
2. y/n/skip review with reason capture feeding `coding-agent-refine`.
3. Persistent conversation + `/context`-style summary + compaction.
4. Skills loading (shared `~/.agents/skills` with the Racket agent).
5. JSON provider profiles (global + project-local).
6. Full tool-calling agentic mode via gptel tools, with the repetition/malformed
   call guards from `chat-loop.rkt`/`tools.rkt`.
7. Optional: web search enrichment; session token/cost tracking.
