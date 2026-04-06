# CODING-AGENT.EL DOCUMENTATION

#### LLM-Powered Coding Agent for Emacs using gptel

TABLE OF CONTENTS
-----------------
1. Overview
2. Features
3. Requirements
4. Installation
5. Quick Start
6. Usage Guide
   6.1 Single-File Mode
   6.2 Multi-File Project Mode
   6.3 Reviewing Changes
   6.4 Applying Changes
   6.5 Evaluating Code
7. Keybindings Reference
8. Supported Languages
9. Configuration
10. Command Reference
11. License

## 1. OVERVIEW


coding-agent.el is an LLM-powered coding agent for Emacs that integrates with
the gptel package. It allows you to send coding instructions to a language
model and review/apply the proposed changes through an interactive ediff
session.

## 2. FEATURES

- Single-file mode: Send coding instructions to an LLM for the current buffer
- Multi-file project mode: Apply changes across an entire project
- Interactive diff review: Review proposed changes via ediff before accepting
- Language-aware: Automatic detection and evaluation for multiple languages
- Seamless integration: Works with your existing gptel backend configuration

![Emacs Coding Agent screen shot](coding-agent.jpg)


## 3. REQUIREMENTS

Software:
- Emacs 29+
- gptel package (https://github.com/karthink/gptel)
- straight.el (https://github.com/radian-software/straight.el) for installation

External tools:
- rg (ripgrep) or find - for project file discovery
- diff - for generating unified diffs

## 4. INSTALLATION

Place coding-agent.el in your load path and add to your configuration:

    (use-package coding-agent
      :straight (:local-repo "~/GITHUB/coding-agent"))

## 5. QUICK START

1. Open a source file
2. Run M-x ca-run-agent (or C-c a r)
3. Enter an instruction (e.g., "add comments", "refactor to use let*")
4. Review the diff in ediff
5. Press q and answer y to apply changes

## 6. USAGE GUIDE

There are two modes, one for single file projects and one for many file projects.

### 6.1 Single-File Mode

Command: ca-run-agent (C-c a r)

Sends the current buffer's source code to the LLM along with your instruction.
Example instructions:
  - "add comments"
  - "refactor to use let* instead of let"
  - "add type hints to all function arguments"

### 6.2 Multi-File Project Mode

Command: ca-run-agent-project (C-c a p)

Collects all source files in the current directory and subdirectories, filtered
to the current language's extensions. Uses `rg --files` when available, falling
back to `find` otherwise.

Files under hidden directories and common build/dependency directories are
automatically excluded:
  - .git, .hg, .svn
  - node_modules, target, vendor
  - __pycache__, .mypy_cache, .tox
  - dist, build, .build, _build
  - .cpcache, .clj-kondo, .lsp
  - .stack-work, .gradle

The LLM returns modified files using FILE: <path> / END_FILE delimiters, and
each file is reviewed individually.

## 6.3 Reviewing Changes

When the LLM responds, the following buffers are created:
  - *agent-proposed* - the full rewritten code
  - *agent-diff* - a unified diff of original vs proposed

An ediff session launches automatically for side-by-side comparison. For
multi-file responses, each modified file gets its own ediff session in
sequence, allowing independent accept/reject decisions.

## 6.4 Applying Changes

Option A (quick):
  M-x ca-apply-proposed
  Writes the proposed code to the source buffer and saves the file.

Option B (via ediff):
  Navigate diffs with n/p, then press q to quit ediff.
  Answer y to the "Apply proposed changes?" prompt.

## 6.5 Evaluating Code

Command: ca-eval-buffer-for-language (C-c a e)

Runs the appropriate checker/evaluator for the buffer's language:
  - Python       → python-shell-send-buffer
  - Common Lisp  → slime-compile-and-load-file
  - Clojure      → cider-load-buffer

## 7. KEYBINDINGS REFERENCE


| Key     | Command                       | Description                    |
|---------|-------------------------------|--------------------------------|
| C-c a r | ca-run-agent                  | Send instruction (single file) |
| C-c a p | ca-run-agent-project          | Send instruction (whole proj)  |
| C-c a e | ca-eval-buffer-for-language   | Evaluate/syntax-check buffer   |
| C-c a h | ca-help                       | Show help message              |
| C-c l r | my-llm-send-region-or-buffer  | Raw gptel chat                 |
| C-c l c | gptel-chat                    | Open gptel chat buffer         |


## 8. SUPPORTED LANGUAGES


Language        | Extensions
----------------|---------------------------
Python          | .py
Common Lisp     | .lisp, .cl, .asd
Clojure         | .clj, .cljs, .cljc, .edn
JavaScript      | .js, .mjs, .cjs
TypeScript      | .ts, .tsx
Ruby            | .rb
Go              | .go
Rust            | .rs
C               | .c, .h
C++             | .cpp, .cc, .cxx, .hpp, .hh
Java            | .java
Emacs Lisp      | .el
Markdown        | .md
Shell           | .sh, .bash, .zsh

## 9. CONFIGURATION

The package uses your existing gptel backend configuration. Set these variables before using coding-agent:

- gptel-backend - your configured gptel backend
- gptel-model   - the model to use

Example Ollama configuration (included in coding-agent.el):

  (defvar my-ollama-backend
    (gptel-make-ollama "Ollama"
      :host "localhost:11434"
      :models '(glm-5:cloud)
      :stream t))

  (setq gptel-backend my-ollama-backend
        gptel-model  'glm-5:cloud)

## 10. COMMAND REFERENCE

ca-run-agent (INSTRUCTION): Send INSTRUCTION about the current source buffer to the LLM.

ca-run-agent-project (INSTRUCTION): Send INSTRUCTION about the whole project to the LLM. Collects source files
  under default-directory matching the current buffer's language extensions.

ca-apply-proposed (&optional PROPOSED-TEXT): Replace the contents of ca-source-buffer with proposed text and save.

ca-eval-buffer-for-language: Run appropriate eval/check for current buffer's language.

ca-help: Display a short usage cheatsheet in *Messages*.

## 11. LICENSE

GPL-3.0 Licensed

