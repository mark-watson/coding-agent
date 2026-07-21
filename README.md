# coding-agent.el

An LLM-powered coding agent for Emacs, built on [gptel](https://github.com/karthink/gptel).
It sends an instruction plus your source code to a language model, shows the proposed
changes as a diff, and writes them only after you confirm — for a single file or
across a whole project.

**Make sure you read the material in the [`documentation/`](documentation/) directory.**

Please note that I used early versions of `coding-agent.el` to both develop later
versions and to help build the documentation.

Screenshot showing `coding-agent.el` on a multi-file Clojure project:

![Emacs Coding Agent screen shot](documentation/coding-agent.jpg)

## Features

- **Single-file and whole-project editing** — `coding-agent-run` for the current
  buffer, `coding-agent-run-project` across the directory tree.
- **Two response formats** — the model may reply with the complete new file, or with
  one or more `SEARCH`/`REPLACE` blocks. Blocks are applied by exact match; any block
  that does not match is reported and skipped rather than corrupting the file.
- **Review before writing** — every change is shown as a unified diff in
  `*coding-agent-diff*`; nothing touches your buffer until you answer `y`. Multi-file
  responses are reviewed one file at a time.
- **Iterative refinement** — `coding-agent-refine` sends a follow-up using the last
  proposal as the new source, so you can converge without retyping the request.
- **Safety rails** — automatic `FILE.coding-agent.bak` backups, a truncated-response
  guard, an optional post-apply delimiter check, a project size cap, and confirmation
  before any project is sent.
- **Privacy filtering** — secret files (`.env`, `*.pem`, `*.key`, `*credential*`,
  `*secret*`, SSH keys, …) and binary files are never sent to the LLM.
- **Language-aware** — detects the language from the major mode (including
  tree-sitter modes), evaluates/loads the buffer where a runtime exists, and runs a
  delimiter check elsewhere.
- **Multiple providers** — defaults to Fireworks.ai but switches at runtime between
  Fireworks.ai, local Ollama, and the Anthropic API with `C-c a m`, independent of the
  `gptel-backend` you use for ordinary chat. Ollama model choices are read live from
  `ollama list`.
- **Transient menu** — `C-c a .` opens a one-key command menu.

## Requirements

- Emacs 29.1+
- [gptel](https://github.com/karthink/gptel) 0.9+
- Built-in: `cl-lib`, `diff`, `diff-mode`, `transient`
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) recommended for project
  mode; falls back to `find`
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
;;   C-c a r / p / f / a / e / . / h   and   C-c l r / c
(global-coding-agent-mode 1)

(provide 'coding-agent-config)
```

> **Backend note.** The editing commands use the agent's own backend — Fireworks.ai by
> default (`accounts/fireworks/models/deepseek-v4-flash`, read via `FIREWORKS_API_KEY`) —
> regardless of the global `gptel-backend`. Setting `gptel-backend`/`gptel-model` only
> affects plain `M-x gptel` usage. Switch the agent's provider at runtime with
> `coding-agent-model-change` (`C-c a m`); see [Configuration](#configuration).

## Quick Start

1. Open a source file.
2. Run `M-x coding-agent-run` (or `C-c a r`).
3. Enter an instruction (e.g. *"add docstrings"*, *"refactor to use let\* instead of let"*).
4. Review the change in the `*coding-agent-diff*` buffer that pops up.
5. Answer `y` to the *"Apply proposed changes to …?"* prompt.

Nothing is written to disk automatically: after applying, the buffer is modified but
unsaved, so you can still inspect or undo before `C-x C-s`.

## Keybindings

Active when `coding-agent-mode` (or `global-coding-agent-mode`) is on:

| Key | Command | Description |
|-----|---------|-------------|
| `C-c a r` | `coding-agent-run` | Edit the current file |
| `C-c a p` | `coding-agent-run-project` | Edit across the project |
| `C-c a f` | `coding-agent-refine` | Follow-up on the last result |
| `C-c a a` | `coding-agent-apply-proposed` | Apply the stashed proposal |
| `C-c a e` | `coding-agent-eval-buffer-for-language` | Evaluate / syntax-check the buffer |
| `C-c a .` | `coding-agent-dispatch` | Transient command menu |
| `C-c a m` | `coding-agent-model-change` | Switch provider / model |
| `C-c a h` | `coding-agent-help` | Show the cheatsheet |
| `C-c l r` | `coding-agent-send-region-or-buffer` | Send region/buffer as a raw request |
| `C-c l c` | `coding-agent-open-chat` | Open a gptel chat buffer |

## How it works

**Response protocol.** The agent asks the model to reply with either the complete new
file (raw source, no fences) or one or more search/replace blocks:

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

**Review & apply.** The proposal is shown as a unified diff against the original in
`*coding-agent-diff*` (a `diff-mode` buffer, reused across runs and left open for
inspection); the raw model reply is kept in `*coding-agent-raw*` (or
`*coding-agent-project-raw*`). Applying replaces the buffer text but does not save
unless you set `coding-agent-apply-saves-buffer`.

**Safety.** Before applying, the file is copied to `FILE.coding-agent.bak` (unless
disabled). Whole-file output smaller than `coding-agent-min-proposed-ratio` of the
original triggers a confirmation, guarding against truncated replies. Optionally
(`coding-agent-check-after-apply`) a delimiter check runs afterwards on lisp-family code
and offers to revert.

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

### Switching providers

`coding-agent-model-change` (`C-c a m`) switches the provider and model at runtime.
Three providers are built in:

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
For every provider the model prompt also
accepts a name that is not in the list, so you can use any model it serves. The static
lists (a fallback for Ollama, the offered set for the others) are
`coding-agent-fireworks-models`, `coding-agent-ollama-local-models`, and
`coding-agent-anthropic-models`.

The agent binds `gptel-backend`/`gptel-model` for every request, so a global gptel
backend never changes which provider the agent uses. To add or reshape providers, edit
`coding-agent--providers` — each entry names a label, a `gptel-make-*` backend, a model
list, and an optional key variable.

## License

GPL-3.0
