# coding-agent.el

An LLM-powered coding agent for Emacs, built on [gptel](https://github.com/karthink/gptel).
It sends an instruction plus your source code to a language model, shows the proposed
changes as a diff, and writes them only after you confirm — for a single file, across a
whole project, or as a full agentic session where the model drives with tools.

**Make sure you read the material in the [`documentation/`](documentation/) directory.**

Please note that I used early versions of `coding-agent.el` to both develop later
versions and to help build the documentation.

Screenshot showing `coding-agent.el` on a multi-file Clojure project:

![Emacs Coding Agent screen shot](documentation/coding-agent.jpg)

## Features

- **Three scopes** — `coding-agent-run` for the current buffer,
  `coding-agent-run-project` across the directory tree, and `coding-agent-agent-run`
  for an agentic, multi-turn session.
- **Agentic tool use** — in agentic mode the model explores and edits via tools
  (`read_file`, `list_dir`, `grep`, whitelisted `run_shell`, and `propose_edit`),
  mirrors the companion `racket-coding-agent` design. Edits are reviewed per file,
  then written and checked.
- **Two response formats** — the model may reply with the complete new file, or with
  one or more `SEARCH`/`REPLACE` blocks. Blocks are applied by exact match; any block
  that does not match is reported and skipped rather than corrupting the file.
- **yes/no/skip review** — every change is shown as a unified diff in
  `*coding-agent-diff*`. Answering **s** (skip) asks for a one-line reason that is fed
  back to the model on the next request, so it adjusts instead of retrying blindly.
- **Post-edit test gate** — after every applied edit, `make check` (or any target set
  via `coding-agent-check-command`) runs in the project root; failures are shown and
  can be fed back to the model as a follow-up.
- **Iterative refinement** — `coding-agent-refine` sends a follow-up using the last
  proposal as the new source, with any skip reasons and check output attached, so you
  can converge without retyping the request.
- **Safety rails** — automatic `FILE.coding-agent.bak` backups, a truncated-response
  guard, an optional post-apply delimiter check, a project size cap, confirmation
  before any project is sent, and dry-run/auto-approve modes
  (`coding-agent-toggle-dry-run`, `coding-agent-toggle-auto-approve`).
- **Privacy filtering** — secret files (`.env`, `*.pem`, `*.key`, `*credential*`,
  `*secret*`, SSH keys, …) and dotfiles/Emacs-internal files are never sent to the
  LLM, in both batch and tool modes.
- **Language-aware** — detects the language from the major mode (including
  tree-sitter modes), evaluates/loads the buffer where a runtime exists, and runs a
  delimiter check elsewhere.
- **Conversation session** — per-buffer history (`coding-agent-show-history`), a
  tabular context summary with estimated tokens (`coding-agent-show-context`), and
  one-shot LLM compaction (`coding-agent-compact-context`).
- **Skills** — load reference material into future prompts with
  `coding-agent-load-skill` (`C-c a /`), reading `~/.agents/skills/<name>/SKILL.md`
  (same layout as the command-line agent, so skills are shared).
- **Web search enrichment** — Brave or Exa results can be prepended to the next
  instruction: run `coding-agent-enrich-with-search` (`C-c a s`) once, toggle every
  request with `coding-agent-toggle-search` (`C-c a S`), or use a prefix argument on
  `run`/`refine`/`run-project`/`agent-run`.
- **Session usage** — `coding-agent-session-usage` (`C-c a u`) shows cumulative
  prompt/completion tokens reported by providers.
- **JSON provider profiles** — declare extra OpenAI-compatible or Ollama/MLX-style
  providers in `~/.coding_harness.json` (global) and `.coding_agent_harness.json`
  (project-local, deep-merged over the global) without writing any elisp; see
  [Configuration](#configuration).
- **Multiple providers** — defaults to Fireworks.ai but switches at runtime between
  Fireworks.ai, local Ollama, the Anthropic API, and any JSON-defined profile with
  `C-c a m`, independent of the `gptel-backend` you use for ordinary chat. Ollama
  model choices are read live from `ollama list`.
- **Transient menu** — `C-c a .` opens a one-key command menu.

## Requirements

- Emacs 29.1+
- [gptel](https://github.com/karthink/gptel) 0.9+
- Built-in: `cl-lib`, `diff`, `diff-mode`, `json`, `transient`
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) recommended for project
  mode and for the agentic `grep` tool; falls back to `find`/`grep`
- A Fireworks.ai API key in the `FIREWORKS_API_KEY` environment variable (or
  customize the backend — see [Configuration](#configuration))

## Installation

The library does **not** enable any keybindings when loaded — you turn them on with
`global-coding-agent-mode`. The recommended setup keeps your personal settings in a
small `coding-agent-config.el` that your `~/.emacs` loads.

### 1. Set your API key

Export the key in your shell profile so Emacs inherits it:

```sh
export FIREWORKS_API_KEY="fw_..."
```

### 2. Load a personal config from `~/.emacs`

```lisp
;;;;;  My coding agent:

(let ((coding-agent-config "/Users/markw/GITHUB/emacs_setup/coding-agent-config.el"))
  (when (file-exists-p coding-agent-config)
    (load coding-agent-config)))
```

### 3. Example `coding-agent-config.el`

This makes the library discoverable, loads it, and turns the keybindings on
everywhere:

```lisp
;;; coding-agent-config.el --- personal coding-agent setup -*- lexical-binding: t; -*-

;; Make the library discoverable, then load it.
(add-to-list 'load-path "~/GITHUB/coding-agent")
(require 'gptel)
(require 'coding-agent)

;; Optional: a backend for ordinary `M-x gptel' chat.  This is independent of the
;; agent, which uses its own backend (Fireworks by default; see the note below).
(defvar coding-agent-ollama-backend
  (gptel-make-ollama "Ollama"
    :host "localhost:11434"
    :models '(glm-5:cloud)
    :stream t))
(setq gptel-backend coding-agent-ollama-backend
      gptel-model 'glm-5:cloud)

;; Enable the agent's keybindings everywhere:
;;   C-c a r / p / R / f / a / e / . / h   and   C-c l r / c
(global-coding-agent-mode 1)

(provide 'coding-agent-config)
```

> **Backend note.** The editing commands use the agent's own backend — Fireworks.ai by
> default (`accounts/fireworks/models/deepseek-v4-flash`, read via `FIREWORKS_API_KEY`) —
> regardless of the global `gptel-backend`. Setting `gptel-backend`/`gptel-model` only
> affects plain `M-x gptel` usage. Switch the agent's provider at runtime with
> `coding-agent-model-change` (`C-c a m`) or declare more providers with JSON config;
> see [Configuration](#configuration).

## Quick Start

1. Open a source file.
2. Run `M-x coding-agent-run` (or `C-c a r`).
3. Enter an instruction (e.g. *"add docstrings"*, *"refactor to use let\* instead of let"*).
4. Review the change in the `*coding-agent-diff*` buffer that pops up.
5. Answer **y** to apply, **n** to reject, or **s** to skip and tell the model why.

Nothing is written to disk automatically: after applying, the buffer is modified but
unsaved, so you can still inspect or undo before `C-x C-s`.

For a full agentic session instead (the model reads files, greps, runs whitelisted
shell commands, and proposes edits on its own), place point in any file in the project
and run `M-x coding-agent-agent-run` (`C-c a R`).

## Keybindings

Active when `coding-agent-mode` (or `global-coding-agent-mode`) is on:

| Key | Command | Description |
|-----|---------|-------------|
| `C-c a r` | `coding-agent-run` | Edit the current file |
| `C-c a p` | `coding-agent-run-project` | Edit across the project |
| `C-c a R` | `coding-agent-agent-run` | Agentic session with tools |
| `C-c a X` | `coding-agent-agent-stop` | Abort the running agentic session |
| `C-c a f` | `coding-agent-refine` | Follow-up on the last result |
| `C-c a a` | `coding-agent-apply-proposed` | Apply the stashed proposal |
| `C-c a e` | `coding-agent-eval-buffer-for-language` | Evaluate / syntax-check the buffer |
| `C-c a .` | `coding-agent-dispatch` | Transient command menu |
| `C-c a m` | `coding-agent-model-change` | Switch provider / model |
| `C-c a g` | `coding-agent-reset` | Clear a stuck in-progress flag |
| `C-c a h` | `coding-agent-help` | Show the cheatsheet |
| `C-c a H` | `coding-agent-show-history` | Popup conversation history |
| `C-c a T` | `coding-agent-show-context` | Context summary + token estimate |
| `C-c a C` | `coding-agent-compact-context` | LLM-compact the history |
| `C-c a u` | `coding-agent-session-usage` | Token usage this session |
| `C-c a /` | `coding-agent-load-skill` | Load a `~/.agents/skills` skill |
| `C-c a s` | `coding-agent-enrich-with-search` | Web-search-enrich the next request |
| `C-c a S` | `coding-agent-toggle-search` | Search-enrich every request on/off |
| `C-c a D` | `coding-agent-toggle-dry-run` | Show diffs but never write |
| `C-c a A` | `coding-agent-toggle-auto-approve` | Apply without prompting |
| `C-c l r` | `coding-agent-send-region-or-buffer` | Send region/buffer as a raw request |
| `C-c l c` | `coding-agent-open-chat` | Open a gptel chat buffer |

## How it works

**Response protocol (single-file / project).** The agent asks the model to reply with
either the complete new file (raw source, no fences) or one or more search/replace
blocks:

```
<<<<<<< SEARCH
<lines copied verbatim from the current file>
=======
<the replacement lines>
>>>>>>> REPLACE
```

Each `SEARCH` must match the current file exactly. Blocks are applied by exact string
match (tolerating a single trailing-newline difference at end of file); any block that
does not match is reported and skipped, so a partial response never corrupts the file.
In project mode the model returns whole files delimited by `FILE: <path>` … `END_FILE`,
and each is reviewed in turn.

**Agentic mode.** `coding-agent-agent-run` sends the instruction plus a system prompt,
and gptel runs the tool loop: the model calls `read_file`, `list_dir`, `grep`,
`run_shell` (whitelist from `coding-agent-shell-command-whitelist`), and
`propose_edit`, whose `old` argument must match the on-disk file exactly (stale bases
are rejected). Each `propose_edit` triggers the standard diff review; after approval
the file is written and the check command runs, with failures fed back to the model.
The loop halts early when the model repeats the identical tool calls
(`coding-agent-agent-max-iterations` is the hard cap).

**Review & apply.** The proposal is shown as a unified diff against the original in
`*coding-agent-diff*` (a `diff-mode` buffer, reused across runs and left open for
inspection); the raw model reply is kept in `*coding-agent-raw*` (or
`*coding-agent-project-raw*`). Applying replaces the buffer text but does not save
unless you set `coding-agent-apply-saves-buffer`.

**Safety.** Before applying, the file is copied to `FILE.coding-agent.bak` (unless
disabled). Whole-file output smaller than `coding-agent-min-proposed-ratio` of the
original triggers a confirmation, guarding against truncated replies. Optionally
(`coding-agent-check-after-apply`) a delimiter check runs afterwards on lisp-family
code and offers to revert. A proposal identical to the current buffer is a no-op.

## Supported Languages

| Language | Extensions |
|----------|------------|
| Python | `.py`, `.pyi` |
| Common Lisp | `.lisp`, `.cl`, `.asd` |
| Clojure | `.clj`, `.cljs`, `.cljc`, `.edn` |
| JavaScript | `.js`, `.mjs`, `.cjs`, `.jsx` |
| TypeScript | `.ts`, `.tsx` |
| Ruby | `.rb` |
| Go | `.go` |
| Rust | `.rs` |
| C | `.c`, `.h` |
| C++ | `.cpp`, `.cc`, `.cxx`, `.hpp`, `.hh` |
| Java | `.java` |
| Emacs Lisp | `.el` |
| Hy | `.hy` |
| Markdown | `.md` |
| Shell | `.sh`, `.bash`, `.zsh` |

Tree-sitter major modes (`*-ts-mode`) are recognized alongside their classic
counterparts. `coding-agent-eval-buffer-for-language` runs `python-shell-send-buffer`,
`slime-compile-and-load-file`, `cider-load-buffer`, or `eval-buffer` for Python, Common
Lisp, Clojure, and Emacs Lisp respectively; for other languages it runs a delimiter
balance check.

## Configuration

Most options live in the `coding-agent` customize group
(`M-x customize-group RET coding-agent`).

| Variable | Default | Purpose |
|----------|---------|---------|
| `coding-agent-model` | `accounts/fireworks/models/deepseek-v4-flash` | Model the agent sends requests to |
| `coding-agent-backend` | Fireworks.ai backend | gptel backend used for every agent request |
| `coding-agent-apply-saves-buffer` | `nil` | Save automatically after applying |
| `coding-agent-backup-on-apply` | `t` | Write `FILE.coding-agent.bak` before applying |
| `coding-agent-min-proposed-ratio` | `0.5` | Confirm whole-file output smaller than this fraction |
| `coding-agent-check-after-apply` | `nil` | Delimiter check + revert offer after applying |
| `coding-agent-project-max-bytes` | `409600` | Confirm before sending a project larger than this |
| `coding-agent-confirm-project-send` | `t` | Ask before sending project files |
| `coding-agent-ignore-dirs` | build/VCS dirs | Directory names pruned when collecting project files |
| `coding-agent-secret-globs` | `.env`, `*.pem`, … | Filename globs never sent to the LLM |
| `coding-agent-dry-run` | `nil` | Show diffs, never modify buffers or files |
| `coding-agent-auto-approve` | `nil` | Apply proposals without prompting |
| `coding-agent-check-command` | `"check"` | Makefile target run after each applied edit (nil disables) |
| `coding-agent-check-max-output` | `2000` | Cap on retained check output |
| `coding-agent-review-save-window-config` | `t` | Restore window layout after a review |
| `coding-agent-skills-directory` | `~/.agents/skills` | Where skill subdirectories live |
| `coding-agent-search-engine` | `brave` | `brave` or `exa` |
| `coding-agent-shell-command-whitelist` | `("make" "ls" "pwd" "cat" "rg" "grep" "git" "uv")` | Commands the agentic `run_shell` may execute |
| `coding-agent-agent-max-iterations` | `20` | Hard cap on agentic round-trips |

### Switching providers

`coding-agent-model-change` (`C-c a m`) switches the provider and model at runtime.
Three providers are built in; more can be declared in JSON (next section):

| Provider | Backend | Key variable |
|----------|---------|--------------|
| Fireworks.ai | `api.fireworks.ai` (OpenAI-compatible) | `FIREWORKS_API_KEY` |
| Ollama (local) | `localhost:11434` | none |
| Anthropic API | Anthropic | `ANTHROPIC_API_KEY` |

A provider is offered only when its key variable is set (providers that need no key are
always available), so Anthropic appears once `ANTHROPIC_API_KEY` is exported. When you
pick **Ollama (local)**, the model list is read live from `ollama list`, so you choose
among the models you have actually pulled, and requests raise the context window to
`coding-agent-ollama-num-ctx` (16336, sent as `options.num_ctx`) so whole files fit.
For every provider the model prompt also accepts a name that is not in the list, so you
can use any model it serves. The static lists (a fallback for Ollama, the offered set
for the others) are `coding-agent-fireworks-models`, `coding-agent-ollama-local-models`,
and `coding-agent-anthropic-models`.

The agent binds `gptel-backend`/`gptel-model` for every request, so a global gptel
backend never changes which provider the agent uses. To add or reshape providers in
elisp, edit `coding-agent--providers` — each entry names a label, a `gptel-make-*`
backend, a model list, and an optional key variable.

### JSON provider profiles

Instead of elisp, providers can be declared in JSON and merged at startup (and on
demand with `M-x coding-agent-load-harness-config`):

- `~/.coding_harness.json` — global, e.g. personal MLX/Ollama profiles.
- `.coding_agent_harness.json` — in the project root; deep-merged over the global file
  (project wins on conflicts).

Format (all sections optional):

```json
{
  "default_provider": "mlx",
  "providers": {
    "mlx": {
      "type": "mlx",
      "endpoint": "http://localhost:11434/v1/chat/completions",
      "model": "mlx-community/gemma-4-26B-A4B-it-OptiQ-4bit",
      "generation": { "temperature": 0.6, "max_tokens": 32768 }
    },
    "fireworks": {
      "type": "openai",
      "endpoint": "https://api.fireworks.ai/inference/v1/chat/completions",
      "api_key_env": "FIREWORKS_API_KEY",
      "model": "accounts/fireworks/models/deepseek-v4-flash-0731"
    }
  }
}
```

`type` is `"openai"` (any OpenAI-compatible REST endpoint) or `"mlx"` / `"ollama"`
(gptel's Ollama backend, which also talks to MLX/Ollama OpenAI shims); `api_key_env`
names the environment variable holding the Bearer key (omit for key-less local
servers); `generation` parameters are folded into request params.

### Skills and web search

`coding-agent-load-skill` (`C-c a /`) offers every `SKILL.md` found under
`coding-agent-skills-directory` (default `~/.agents/skills`, shared with the CLI
agent); the file's contents are prepended to future prompts from the current buffer.
`coding-agent-clear-skills` unloads them.

`coding-agent-enrich-with-search` (`C-c a s`) runs a Brave or Exa search (choose with
`coding-agent-search-engine`, key in `BRAVE_SEARCH_API_KEY` or `EXA_SEARCH_API_KEY`)
and prepends the formatted results to the next instruction; `coding-agent-toggle-search`
(`C-c a S`) makes every instruction search-enriched.

## License

GPL-3.0
