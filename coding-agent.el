;;; coding-agent.el --- LLM-powered coding agent using gptel -*- lexical-binding: t; -*-

;; Author: Mark Watson
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9"))
;; Keywords: tools, convenience, llm

;;; Commentary:
;;
;; A small coding agent built on top of gptel.  It sends an instruction plus
;; source code to an LLM, shows the proposed changes as a diff, and applies them
;; on your confirmation.  Two scopes are supported:
;;
;;   * single file   -- `coding-agent-run'          (C-c a r)
;;   * whole project -- `coding-agent-run-project'   (C-c a p)
;;
;; The model may answer either with the COMPLETE new file, or with one or more
;; search/replace blocks:
;;
;;   <<<<<<< SEARCH
;;   <lines copied verbatim from the current file>
;;   =======
;;   <replacement lines>
;;   >>>>>>> REPLACE
;;
;; Search/replace edits are applied by exact match: any block whose SEARCH text
;; is not found is reported and skipped rather than corrupting the file.  When
;; the response contains no blocks it is treated as a whole-file replacement.
;;
;; This file configures its own gptel backend.  It defaults to Fireworks.ai
;; (model `accounts/fireworks/models/deepseek-v4-flash'), reading the API key
;; from the FIREWORKS_API_KEY environment variable, and can switch at runtime
;; between Fireworks.ai, a local Ollama server, and the Anthropic API with
;; `coding-agent-model-change' (C-c a m).  A provider whose API-key environment
;; variable is unset is not offered.  It does not enable its keybindings on
;; load; call `(global-coding-agent-mode 1)' in your init (see
;; `coding-agent-config.el' for an example).
;;
;; Key commands (active when `coding-agent-mode' is on):
;;   C-c a r  coding-agent-run                    edit the current file
;;   C-c a p  coding-agent-run-project            edit across the project
;;   C-c a f  coding-agent-refine                 follow-up on the last result
;;   C-c a a  coding-agent-apply-proposed         apply the stashed proposal
;;   C-c a e  coding-agent-eval-buffer-for-language
;;   C-c a .  coding-agent-dispatch               transient menu
;;   C-c a m  coding-agent-model-change           switch provider/model
;;   C-c a g  coding-agent-reset                  clear a stuck in-progress flag
;;   C-c a h  coding-agent-help
;;   C-c l r  coding-agent-send-region-or-buffer  raw gptel request
;;   C-c l c  coding-agent-open-chat              gptel chat buffer

;;; Code:

(require 'gptel)
(require 'gptel-openai)    ; gptel-make-openai    (Fireworks.ai)
(require 'gptel-ollama)    ; gptel-make-ollama    (Ollama local)
(require 'gptel-anthropic) ; gptel-make-anthropic (Anthropic API)
(require 'cl-lib)
(require 'diff)            ; diff-no-select for the review buffer
(require 'diff-mode)
(require 'transient)

;; ---------------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------------

(defgroup coding-agent nil
  "LLM-powered coding agent built on gptel."
  :group 'tools
  :prefix "coding-agent-")

(defcustom coding-agent-apply-saves-buffer nil
  "When non-nil, saving happens automatically after applying a proposal.
The default is nil so that a bad or truncated proposal never overwrites the
file on disk in one step; you review, then save with \\[save-buffer]."
  :type 'boolean)

(defcustom coding-agent-backup-on-apply t
  "When non-nil, copy the file to FILE.coding-agent.bak before applying."
  :type 'boolean)

(defcustom coding-agent-min-proposed-ratio 0.5
  "Confirm before applying whole-file output smaller than this fraction.
Guards against silently accepting a truncated model response."
  :type 'number)

(defcustom coding-agent-check-after-apply nil
  "When non-nil, run a cheap delimiter check after applying and offer to revert."
  :type 'boolean)

(defcustom coding-agent-project-max-bytes (* 400 1024)
  "Confirm before sending a project larger than this many bytes to the LLM."
  :type 'integer)

(defcustom coding-agent-confirm-project-send t
  "When non-nil, ask before sending project files to the LLM."
  :type 'boolean)

(defcustom coding-agent-ignore-dirs
  '(".git" ".hg" ".svn" "node_modules" "target" ".cpcache" ".clj-kondo"
    ".lsp" "__pycache__" ".mypy_cache" ".tox" "dist" "build" ".build"
    ".stack-work" "vendor" "_build" ".gradle" ".venv" ".cargo")
  "Directory names pruned when collecting project files."
  :type '(repeat string))

(defcustom coding-agent-secret-globs
  '(".env" "*.env" ".env.*" "*.pem" "*.key" "*.p12" "*.pfx" "*.pkcs12"
    "id_rsa" "id_dsa" "id_ecdsa" "id_ed25519" "*credential*" "*secret*")
  "Filename globs that are never sent to the LLM in project mode."
  :type '(repeat string))

;; ---------------------------------------------------------------------------
;; Inference backends and provider switching
;; ---------------------------------------------------------------------------
;; The agent routes every request through `coding-agent--request' (and the chat
;; buffer binds the same backend/model), so a global `gptel-backend' set for
;; other gptel usage never changes which provider the agent uses.  The active
;; provider defaults to Fireworks.ai and can be switched at runtime with
;; `coding-agent-model-change' (C-c a m).  Each provider names the environment
;; variable (if any) that must hold its API key; the key is read at request
;; time, and a provider whose variable is unset is not offered in the menu.

(defun coding-agent--env-key (name)
  "Return a function that reads environment variable NAME at call time."
  (lambda () (getenv name)))

(defvar coding-agent-fireworks-models
  '(accounts/fireworks/models/deepseek-v4-flash)
  "Models offered for the Fireworks.ai provider.")

(defvar coding-agent-ollama-local-models
  '(qwen3:latest llama3.2:latest deepseek-r1:latest)
  "Fallback models for a local Ollama server.
`coding-agent-model-change' normally reads the installed models from the
running server; this list is used only when the server cannot be reached.")

(defvar coding-agent-ollama-num-ctx 16336
  "Context window (num_ctx) requested from local Ollama models.
Ollama otherwise defaults to a small context (often 2K-4K); the agent sends
whole files, so this raises it to at least 16K.  It is applied through the
Ollama backend's `:request-params' as (:options (:num_ctx N)).")

(defvar coding-agent-anthropic-models
  '(claude-opus-4-8 claude-sonnet-5 claude-haiku-4-5-20251001)
  "Models offered for the Anthropic API provider.")

(defvar coding-agent--fireworks-backend
  (gptel-make-openai "Fireworks"
    :host "api.fireworks.ai"
    :endpoint "/inference/v1/chat/completions"
    :stream t
    :key (coding-agent--env-key "FIREWORKS_API_KEY")
    :models coding-agent-fireworks-models)
  "gptel backend for Fireworks.ai.")

(defvar coding-agent--ollama-local-backend
  (gptel-make-ollama "Ollama"
    :host "localhost:11434"
    :stream t
    :models coding-agent-ollama-local-models
    :request-params `(:options (:num_ctx ,coding-agent-ollama-num-ctx)))
  "gptel backend for a local Ollama server.
Requests raise the model context window to `coding-agent-ollama-num-ctx'.")

(defvar coding-agent--anthropic-backend
  (gptel-make-anthropic "Anthropic"
    :stream t
    :key (coding-agent--env-key "ANTHROPIC_API_KEY")
    :models coding-agent-anthropic-models)
  "gptel backend for the Anthropic API.")

(defvar coding-agent--providers
  `((fireworks
     :label "Fireworks.ai"   :backend ,coding-agent--fireworks-backend
     :models ,coding-agent-fireworks-models    :env "FIREWORKS_API_KEY")
    (ollama-local
     :label "Ollama (local)" :backend ,coding-agent--ollama-local-backend
     :models ,coding-agent-ollama-local-models :env nil)
    (anthropic
     :label "Anthropic API"  :backend ,coding-agent--anthropic-backend
     :models ,coding-agent-anthropic-models    :env "ANTHROPIC_API_KEY"))
  "Registry of selectable providers.
Each entry is (KEY :label STR :backend BACKEND :models LIST :env VAR-OR-NIL).
A provider is offered by `coding-agent-model-change' only when its :env is nil
or that environment variable is set.")

(defcustom coding-agent-model 'accounts/fireworks/models/deepseek-v4-flash
  "gptel model the coding agent currently sends its requests to.
Change it (and the provider) interactively with `coding-agent-model-change'."
  :type 'symbol)

(defvar coding-agent-backend coding-agent--fireworks-backend
  "Active gptel backend used by the coding agent.
Set by `coding-agent-model-change'; defaults to Fireworks.ai.")

(defvar coding-agent-provider 'fireworks
  "Key of the active provider in `coding-agent--providers'.")

(defun coding-agent--provider (key)
  "Return the provider plist for KEY, or nil."
  (cdr (assq key coding-agent--providers)))

(defun coding-agent--provider-label ()
  "Return the label of the active provider (or its symbol name as a fallback)."
  (or (plist-get (coding-agent--provider coding-agent-provider) :label)
      (format "%s" coding-agent-provider)))

;; Heal a stale selection: if `coding-agent-provider' names a provider that no
;; longer exists (e.g. one was removed and the file reloaded), fall back to the
;; default so the agent never runs with an unknown provider or a nil backend.
(unless (coding-agent--provider coding-agent-provider)
  (setq coding-agent-provider 'fireworks
        coding-agent-backend  coding-agent--fireworks-backend
        coding-agent-model    (car coding-agent-fireworks-models)))

(defun coding-agent--provider-available-p (key)
  "Return non-nil when provider KEY's API-key variable is set (or it needs none)."
  (let ((env (plist-get (coding-agent--provider key) :env)))
    (or (null env) (and (getenv env) t))))

(defun coding-agent--ensure-key ()
  "Signal a `user-error' unless the active provider is valid with its key set."
  (let ((p (coding-agent--provider coding-agent-provider)))
    (cond
     ((null p)
      (user-error "coding-agent: no active provider; run M-x coding-agent-model-change"))
     ((and (plist-get p :env) (not (getenv (plist-get p :env))))
      (user-error "coding-agent: set the %s environment variable for %s"
                  (plist-get p :env) (plist-get p :label))))))

(defun coding-agent--ollama-installed-models ()
  "Return model-name strings installed on the local Ollama server, or nil.
Runs `ollama list' and parses the first column of each row; returns nil when
the `ollama' executable is absent or the command fails."
  (when (executable-find "ollama")
    (condition-case nil
        (with-temp-buffer
          (when (zerop (process-file "ollama" nil t nil "list"))
            (goto-char (point-min))
            (forward-line 1)              ; skip the NAME/ID/SIZE/MODIFIED header
            (let (models)
              (while (not (eobp))
                (let ((line (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))))
                  (when (string-match "\\`\\([^ \t\n]+\\)" line)
                    (push (match-string 1 line) models)))
                (forward-line 1))
              (nreverse models))))
      (error nil))))

(defun coding-agent--model-candidates (key plist)
  "Return a list of model-name strings to offer for provider KEY.
PLIST is the provider's entry.  For `ollama-local' the list comes from the
running server when reachable, falling back to the static models in PLIST."
  (if (eq key 'ollama-local)
      (or (coding-agent--ollama-installed-models)
          (prog1 (mapcar #'symbol-name (plist-get plist :models))
            (message "coding-agent: could not query local Ollama; using fallback list")))
    (mapcar #'symbol-name (plist-get plist :models))))

(defun coding-agent-model-change ()
  "Switch the provider and model the coding agent uses.
Only providers whose API-key environment variable is set are offered;
providers that need no key are always available.  When Ollama (local) is
chosen, its models are read from the running server.  A model name that is not
in the offered list is accepted only after confirmation, so a typo does not
silently become a request for a nonexistent model."
  (interactive)
  (let* ((keys    (cl-remove-if-not #'coding-agent--provider-available-p
                                    (mapcar #'car coding-agent--providers)))
         (labels  (mapcar (lambda (k)
                            (cons (plist-get (coding-agent--provider k) :label) k))
                          keys))
         (current (or (plist-get (coding-agent--provider coding-agent-provider) :label)
                      "none"))
         (label   (completing-read (format "Provider (current: %s): " current)
                                   labels nil t))
         (key     (cdr (assoc label labels))))
    (unless key
      (user-error "coding-agent: no provider selected (still using %s)" current))
    (let* ((plist (coding-agent--provider key))
           (cands (coding-agent--model-candidates key plist))
           ;; `confirm' lets you still enter a model that is not listed, but a
           ;; partial or mistyped name is caught before it becomes a 404.
           (model (cond ((null cands)       (read-string "Model: "))
                        ((null (cdr cands)) (car cands))
                        (t (completing-read "Model: " cands nil 'confirm nil nil
                                            (car cands))))))
      (when (or (null model) (string= model ""))
        (user-error "coding-agent: no model selected (still using %s)" current))
      (setq coding-agent-provider key
            coding-agent-backend  (plist-get plist :backend)
            coding-agent-model    (if (stringp model) (intern model) model))
      (message "coding-agent: now using %s / %s"
               (plist-get plist :label) coding-agent-model))))

(defun coding-agent--ensure-model-registered ()
  "Ensure `coding-agent-model' is listed in `coding-agent-backend's models.
gptel's `gptel--sanitize-model' silently resets `gptel-model' to a backend's
first model when the requested model is not in that backend's :models list.
Registering the model keeps our selection -- for example an Ollama model picked
from `ollama list' -- from being swapped out (which would send the wrong model
and 404)."
  (let ((models (gptel-backend-models coding-agent-backend)))
    (unless (member coding-agent-model models)
      (setf (gptel-backend-models coding-agent-backend)
            (cons coding-agent-model models)))))

(defun coding-agent--request (prompt &rest args)
  "Send PROMPT via `gptel-request', forcing the agent's backend and model.
ARGS are forwarded to `gptel-request' unchanged.  Binding `gptel-backend' and
`gptel-model' here makes the agent use the provider chosen with
`coding-agent-model-change' regardless of any global gptel configuration."
  (coding-agent--ensure-key)
  (coding-agent--ensure-model-registered)
  (let ((gptel-backend coding-agent-backend)
        (gptel-model coding-agent-model))
    (apply #'gptel-request prompt args)))

;; ---------------------------------------------------------------------------
;; State (buffer-local where possible to avoid clobbering across async runs)
;; ---------------------------------------------------------------------------

(defvar-local coding-agent--proposed-text nil
  "Proposed replacement text stashed for `coding-agent-apply-proposed'.")

(defvar-local coding-agent--original-text nil
  "Original buffer text captured when the last request was sent.")

(defvar-local coding-agent--busy nil
  "Non-nil while a request for this buffer is awaiting a response.")

(defvar coding-agent--project-root nil
  "Root directory of the most recent `coding-agent-run-project' call.")

;; ---------------------------------------------------------------------------
;; Language detection
;; ---------------------------------------------------------------------------

(defconst coding-agent--mode-language-alist
  '((python-mode        . "python")
    (python-ts-mode     . "python")
    (lisp-mode          . "common-lisp")
    (clojure-mode       . "clojure")
    (clojurescript-mode . "clojure")
    (clojurec-mode      . "clojure")
    (clojure-ts-mode    . "clojure")
    (js-mode            . "javascript")
    (js2-mode           . "javascript")
    (js-ts-mode         . "javascript")
    (typescript-mode    . "typescript")
    (typescript-ts-mode . "typescript")
    (tsx-ts-mode        . "typescript")
    (ruby-mode          . "ruby")
    (ruby-ts-mode       . "ruby")
    (go-mode            . "go")
    (go-ts-mode         . "go")
    (rust-mode          . "rust")
    (rust-ts-mode       . "rust")
    (rustic-mode        . "rust")
    (c-mode             . "c")
    (c-ts-mode          . "c")
    (c++-mode           . "c++")
    (c++-ts-mode        . "c++")
    (java-mode          . "java")
    (java-ts-mode       . "java")
    (emacs-lisp-mode    . "emacs-lisp")
    (lisp-interaction-mode . "emacs-lisp")
    (sh-mode            . "shell")
    (bash-ts-mode       . "shell")
    (hy-mode            . "hy")
    (markdown-mode      . "markdown"))
  "Alist mapping major modes (including tree-sitter variants) to languages.")

(defun coding-agent-detect-language (buf)
  "Return a language string for BUF based on its major mode."
  (with-current-buffer buf
    (or (cdr (assq major-mode coding-agent--mode-language-alist))
        (cl-loop for (mode . lang) in coding-agent--mode-language-alist
                 when (derived-mode-p mode) return lang)
        "text")))

(defalias 'coding-agent--buffer-language #'coding-agent-detect-language)

;; ---------------------------------------------------------------------------
;; File classification
;; ---------------------------------------------------------------------------

(defconst coding-agent--language-extensions
  '(("python"      . ("py" "pyi"))
    ("common-lisp" . ("lisp" "cl" "asd"))
    ("clojure"     . ("clj" "cljs" "cljc" "edn"))
    ("javascript"  . ("js" "mjs" "cjs" "jsx"))
    ("typescript"  . ("ts" "tsx"))
    ("ruby"        . ("rb"))
    ("go"          . ("go"))
    ("rust"        . ("rs"))
    ("c"           . ("c" "h"))
    ("c++"         . ("cpp" "cc" "cxx" "hpp" "hh"))
    ("java"        . ("java"))
    ("emacs-lisp"  . ("el"))
    ("markdown"    . ("md"))
    ("hy"          . ("hy"))
    ("shell"       . ("sh" "bash" "zsh")))
  "Alist mapping language strings to lists of file extensions.")

(defconst coding-agent--text-extensions
  '("asd" "bash" "c" "cc" "cfg" "cl" "clj" "cljc" "cljs" "cmake"
    "conf" "cpp" "css" "csv" "cxx" "edn" "el" "ex" "exs"
    "go" "gradle" "graphql" "h" "hh" "hpp" "hs" "html" "ini"
    "java" "js" "json" "jsx" "kt" "lisp" "lua" "makefile" "md"
    "mjs" "ml" "mli" "org" "php" "pl" "pm" "properties" "proto"
    "py" "pyi" "r" "rb" "rs" "rst" "scala" "sh" "sql" "swift" "tex"
    "toml" "ts" "tsx" "txt" "vb" "vue" "xml" "yaml" "yml" "zsh")
  "Extensions treated as plain text.  Others are considered binary.")

(defun coding-agent--text-file-p (filename)
  "Return non-nil when FILENAME looks like a text file.
Files with no extension (Makefile, Dockerfile, ...) count as text."
  (let ((ext (file-name-extension filename)))
    (or (null ext)
        (member (downcase ext) coding-agent--text-extensions))))

(defun coding-agent--secret-file-p (file)
  "Return non-nil when FILE's name matches `coding-agent-secret-globs'."
  (let ((base (file-name-nondirectory file)))
    (cl-some (lambda (glob) (string-match-p (wildcard-to-regexp glob) base))
             coding-agent-secret-globs)))

(defun coding-agent--extensions-for-language (lang)
  "Return the list of file extensions appropriate for LANG."
  (cdr (assoc lang coding-agent--language-extensions)))

;; ---------------------------------------------------------------------------
;; Prompt construction
;; ---------------------------------------------------------------------------

(defconst coding-agent--protocol-help
  "Return your changes as one or more search/replace blocks in EXACTLY this form:

<<<<<<< SEARCH
<lines copied verbatim from the current file>
=======
<the replacement lines>
>>>>>>> REPLACE

Rules:
- SEARCH text must match the current file EXACTLY, whitespace included.
- Include just enough surrounding context to locate each edit unambiguously.
- Use several blocks for several separate edits.
- Alternatively, if a full rewrite is simpler, return the COMPLETE new file as
  raw source with no fences and no markers.
- Output ONLY code (blocks or full file); no prose, no markdown fences."
  "Shared description of the accepted response format.")

(defun coding-agent--build-prompt (language source instruction)
  "Build a single-file LLM prompt for LANGUAGE, SOURCE and INSTRUCTION."
  (format "You are an expert %s programmer.

INSTRUCTION: %s

%s

CURRENT FILE:
%s"
          language instruction coding-agent--protocol-help source))

(defun coding-agent--build-project-prompt (language files-alist instruction)
  "Build a multi-file LLM prompt for LANGUAGE.
FILES-ALIST is a list of (relative-path . content).  INSTRUCTION is the request."
  (let ((files-block
         (mapconcat (lambda (pair)
                      (format "FILE: %s\n%s\nEND_FILE" (car pair) (cdr pair)))
                    files-alist "\n\n")))
    (format "You are an expert %s programmer working on a multi-file project.

INSTRUCTION: %s

Below are the project source files, each delimited by
  FILE: <relative-path>
  <content>
  END_FILE

Return ONLY the files you change, using the SAME delimiters.  Inside a file
return either the COMPLETE new content or search/replace blocks:

<<<<<<< SEARCH
<lines copied verbatim>
=======
<replacement lines>
>>>>>>> REPLACE

Do NOT include unchanged files.  Do NOT add commentary or markdown fences.

PROJECT FILES:
%s"
            language instruction files-block)))

;; ---------------------------------------------------------------------------
;; Response parsing and edit application
;; ---------------------------------------------------------------------------

(defun coding-agent--strip-fences (text)
  "Remove surrounding markdown code fences from TEXT if present."
  (let ((s (string-trim text)))
    (when (string-match "\\`[ \t]*```[a-zA-Z0-9_+-]*\n?" s)
      (setq s (substring s (match-end 0))))
    (when (string-match "\n?[ \t]*```[ \t]*\\'" s)
      (setq s (substring s 0 (match-beginning 0))))
    s))

(defun coding-agent--parse-search-replace-blocks (text)
  "Parse search/replace blocks from TEXT into a list of (SEARCH . REPLACE)."
  (let ((blocks '())
        (start 0))
    (while (string-match "^<<<<<<<+[ \t]*SEARCH[^\n]*\n" text start)
      (let* ((search-start (match-end 0))
             (sep (string-match "^=======*[^\n]*\n" text search-start)))
        (if (not sep)
            (setq start (length text))     ; malformed: stop
          (let* ((search (substring text search-start sep))
                 (replace-start (match-end 0))
                 (endm (string-match "^>>>>>>>+[ \t]*REPLACE[^\n]*" text replace-start)))
            (if (not endm)
                (setq start (length text))  ; malformed: stop
              (push (cons search (substring text replace-start endm)) blocks)
              (setq start (match-end 0)))))))
    (nreverse blocks)))

(defun coding-agent--apply-search-replace (original blocks)
  "Apply BLOCKS, a list of (SEARCH . REPLACE), to ORIGINAL.
Return a cons (RESULT . FAILURES); FAILURES lists SEARCH strings not found."
  (let ((result original)
        (failures '()))
    (dolist (block blocks)
      (let* ((search (car block))
             (replace (cdr block))
             (idx (string-search search result)))
        (cond
         (idx
          (setq result (concat (substring result 0 idx)
                               replace
                               (substring result (+ idx (length search))))))
         ;; Tolerate a single trailing newline mismatch (common at EOF).
         ((and (string-suffix-p "\n" search)
               (setq idx (string-search (substring search 0 -1) result)))
          (let ((s (substring search 0 -1))
                (r (if (string-suffix-p "\n" replace)
                       (substring replace 0 -1) replace)))
            (setq result (concat (substring result 0 idx)
                                 r
                                 (substring result (+ idx (length s)))))))
         (t (push search failures)))))
    (cons result (nreverse failures))))

(defun coding-agent--apply-edits-to-string (original response)
  "Produce the edited form of ORIGINAL from the LLM RESPONSE.
Return a plist with :text, :mode (search-replace or whole-file),
:failures and :count."
  (let ((blocks (coding-agent--parse-search-replace-blocks response)))
    (if blocks
        (let ((res (coding-agent--apply-search-replace original blocks)))
          (list :text (car res) :mode 'search-replace
                :failures (cdr res) :count (length blocks)))
      (list :text (coding-agent--strip-fences response)
            :mode 'whole-file :failures nil :count 1))))

(defun coding-agent--parse-multi-file-response (response)
  "Parse RESPONSE into an alist of (relative-path . body).
Expects FILE: <path> ... END_FILE per file.  A final block missing its
END_FILE is captured whole and the scan then stops (never loops)."
  (let ((result '())
        (start 0))
    (while (string-match "^FILE:[ \t]*\\([^\n]+\\)\n" response start)
      (let* ((path (string-trim (match-string 1 response)))
             (content-start (match-end 0))
             (endm (string-match "^END_FILE[ \t]*$" response content-start)))
        (if endm
            (progn
              (push (cons path (substring response content-start endm)) result)
              (setq start (match-end 0)))
          (push (cons path (substring response content-start)) result)
          (setq start (length response)))))
    (nreverse result)))

;; ---------------------------------------------------------------------------
;; Project file collection (process-file, no shell string building)
;; ---------------------------------------------------------------------------

(defun coding-agent--collect-with-rg (root exts)
  "Collect files under ROOT matching EXTS using ripgrep."
  (let ((args (list "--files" "--color=never")))
    (dolist (d coding-agent-ignore-dirs)
      (setq args (append args (list "-g" (format "!%s/**" d)))))
    (dolist (g coding-agent-secret-globs)
      (setq args (append args (list "-g" (format "!%s" g)))))
    (dolist (e exts)
      (setq args (append args (list "-g" (format "*.%s" e)))))
    (setq args (append args (list root)))
    (with-temp-buffer
      (apply #'process-file "rg" nil t nil args)
      (split-string (buffer-string) "\n" t))))

(defun coding-agent--or-join (flag values)
  "Return a flat list FLAG V1 -o FLAG V2 ... for find expressions."
  (let (acc)
    (dolist (v values)
      (setq acc (append acc (list flag v "-o"))))
    (butlast acc)))

(defun coding-agent--collect-with-find (root exts)
  "Collect files under ROOT matching EXTS using find."
  (let* ((dir-names (coding-agent--or-join "-name" coding-agent-ignore-dirs))
         (name-globs (coding-agent--or-join
                      "-name" (mapcar (lambda (e) (concat "*." e)) exts)))
         (args (append (list root "(" "-type" "d" "(")
                       dir-names
                       (list ")" "-prune" ")" "-o" "(" "-type" "f")
                       (when exts (append (list "(") name-globs (list ")")))
                       (list "-print" ")"))))
    (with-temp-buffer
      (apply #'process-file "find" nil t nil args)
      (split-string (buffer-string) "\n" t))))

(defun coding-agent--collect-project-files (root lang)
  "Return sorted absolute paths of LANG source files under ROOT.
Uses ripgrep when available (which also honors .gitignore), else find.
Binary and secret files are always excluded."
  (let* ((exts (coding-agent--extensions-for-language lang))
         (files (if (executable-find "rg")
                    (coding-agent--collect-with-rg root exts)
                  (coding-agent--collect-with-find root exts))))
    (sort (cl-remove-if-not
           (lambda (f)
             (and (file-regular-p f)
                  (coding-agent--text-file-p f)
                  (not (coding-agent--secret-file-p f))))
           files)
          #'string<)))

(defun coding-agent--file-contents (abs)
  "Return the contents of file ABS as a string."
  (with-temp-buffer
    (insert-file-contents abs)
    (buffer-substring-no-properties (point-min) (point-max))))

;; ---------------------------------------------------------------------------
;; Review (diff buffer) and application
;; ---------------------------------------------------------------------------

(defun coding-agent--kill-buffer-safe (buf)
  "Kill BUF if it is live."
  (when (buffer-live-p buf) (kill-buffer buf)))

(defun coding-agent--diff-strings (original proposed name)
  "Return a diff buffer NAME comparing the ORIGINAL and PROPOSED strings.
The buffer is a read-only `diff-mode' unified diff and is reused (by NAME)
across runs, so \"the diff buffer\" is always the same well-known buffer."
  (let ((a        (get-buffer-create " *coding-agent-diff-a*"))
        (b        (get-buffer-create " *coding-agent-diff-b*"))
        (diff-buf (get-buffer-create name)))
    (with-current-buffer a (erase-buffer) (insert original))
    (with-current-buffer b (erase-buffer) (insert proposed))
    (unwind-protect
        (diff-no-select a b nil t diff-buf)
      (coding-agent--kill-buffer-safe a)
      (coding-agent--kill-buffer-safe b))
    (with-current-buffer diff-buf (goto-char (point-min)))
    diff-buf))

(defun coding-agent--review (src original proposed after-fn)
  "Show a diff of ORIGINAL vs PROPOSED for SRC, then ask whether to apply.
AFTER-FN receives non-nil when the user chose to apply.  Review uses a plain
`*coding-agent-diff*' buffer (visible in the buffer list); no ediff session and
no proposed-buffer pop-up are created."
  (let ((diff-buf (coding-agent--diff-strings original proposed
                                              "*coding-agent-diff*")))
    (display-buffer diff-buf)
    (let ((apply? (and (buffer-live-p src)
                       (y-or-n-p (format "Apply proposed changes to %s? "
                                         (buffer-name src))))))
      (funcall after-fn apply?))))

(defun coding-agent--backup (buffer)
  "Copy BUFFER's file to FILE.coding-agent.bak if it exists."
  (let ((file (buffer-file-name buffer)))
    (when (and file (file-exists-p file))
      (copy-file file (concat file ".coding-agent.bak") t))))

(defun coding-agent--syntax-ok-p (buffer)
  "Return non-nil unless BUFFER has obviously unbalanced delimiters.
Only lisp-family languages are checked; others are assumed OK."
  (with-current-buffer buffer
    (if (member (coding-agent-detect-language buffer)
                '("emacs-lisp" "common-lisp" "clojure" "hy"))
        (condition-case nil
            (save-excursion (goto-char (point-min)) (check-parens) t)
          (error nil))
      t)))

(defun coding-agent--check-and-maybe-revert (buffer original)
  "If BUFFER fails `coding-agent--syntax-ok-p', offer to restore ORIGINAL."
  (unless (coding-agent--syntax-ok-p buffer)
    (when (yes-or-no-p
           "coding-agent: applied code has unbalanced delimiters; revert? ")
      (with-current-buffer buffer
        (erase-buffer)
        (insert original)))))

(defun coding-agent--apply-text (buffer text &optional original)
  "Replace BUFFER contents with TEXT.
When ORIGINAL is given, guard against a suspiciously small (truncated)
whole-file replacement and, if `coding-agent-check-after-apply', verify
delimiters afterwards.  Saving only happens when
`coding-agent-apply-saves-buffer' is non-nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and original (> (length original) 0)
                 (< (/ (float (length text)) (length original))
                    coding-agent-min-proposed-ratio)
                 (not (yes-or-no-p
                       (format "Proposed text is %d%% of the original size; apply anyway? "
                               (round (* 100 (/ (float (length text))
                                                (length original))))))))
        (user-error "coding-agent: apply aborted"))
      (when coding-agent-backup-on-apply
        (coding-agent--backup buffer))
      (let ((pos (point)))
        (erase-buffer)
        (insert text)
        (unless (string-suffix-p "\n" text) (insert "\n"))
        (goto-char (min pos (point-max))))
      (when coding-agent-apply-saves-buffer
        (save-buffer))
      (when (and coding-agent-check-after-apply original)
        (coding-agent--check-and-maybe-revert buffer original))
      (message "coding-agent: applied changes to %s (%s)"
               (buffer-name buffer)
               (if coding-agent-apply-saves-buffer "saved" "unsaved")))))

(defun coding-agent--begin-review (src original proposed after-fn)
  "Stash state on SRC and start a diff review of ORIGINAL vs PROPOSED."
  (when (buffer-live-p src)
    (with-current-buffer src
      (setq coding-agent--proposed-text proposed
            coding-agent--original-text original)))
  (coding-agent--review src original proposed after-fn))

(defun coding-agent-apply-proposed ()
  "Apply the proposal stashed for the current buffer and (optionally) save."
  (interactive)
  (let ((text (buffer-local-value 'coding-agent--proposed-text (current-buffer))))
    (if (not text)
        (user-error "coding-agent: no proposed text for this buffer")
      (coding-agent--apply-text
       (current-buffer) text
       (buffer-local-value 'coding-agent--original-text (current-buffer))))))

;; ---------------------------------------------------------------------------
;; Busy guard and error reporting
;; ---------------------------------------------------------------------------

(defun coding-agent--set-busy (buffer state)
  "Set the busy flag of BUFFER to STATE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (setq coding-agent--busy state))))

(defun coding-agent--ensure-not-busy ()
  "Signal a `user-error' if the current buffer has a request in flight."
  (when coding-agent--busy
    (user-error
     "coding-agent: a request for this buffer is already in progress (M-x coding-agent-reset clears it)")))

(defun coding-agent-reset ()
  "Clear the in-progress flag for the current buffer.
Use this if a request failed in a way that left the buffer marked busy."
  (interactive)
  (setq coding-agent--busy nil)
  (message "coding-agent: cleared in-progress flag for %s" (buffer-name)))

(defun coding-agent--report-error (info)
  "Report a gptel error described by INFO in a readable form.
Includes the HTTP status and the provider error message when present, such as
the model-not-found reply from Ollama that usually causes a 404 on /api/chat."
  (let* ((status (or (plist-get info :http-status) (plist-get info :status)))
         (err    (plist-get info :error))
         (detail (cond ((null err) nil)
                       ((stringp err) err)
                       ((and (listp err) (plist-get err :message)) (plist-get err :message))
                       (t (format "%S" err)))))
    (message "coding-agent: request failed%s%s"
             (if status (format " (%s)" status) "")
             (if detail (concat ": " detail) ""))))

(defun coding-agent--stash-raw (text &optional name)
  "Store TEXT in buffer NAME (default *coding-agent-raw*) for inspection."
  (with-current-buffer (get-buffer-create (or name "*coding-agent-raw*"))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text)
      (goto-char (point-min)))))

;; ---------------------------------------------------------------------------
;; Single-file agent
;; ---------------------------------------------------------------------------

(defun coding-agent--single-callback (src original)
  "Return a gptel callback for a single-file run on SRC with ORIGINAL text."
  (lambda (response info)
    (cond
     ((null response)
      (coding-agent--set-busy src nil)
      (coding-agent--report-error info))
     ((not (stringp response)) nil)     ; reasoning/thinking block: ignore
     (t
      (coding-agent--set-busy src nil)
      (coding-agent--stash-raw response)
      (let* ((edit     (coding-agent--apply-edits-to-string original response))
             (proposed (plist-get edit :text))
             (failures (plist-get edit :failures)))
        (when failures
          (message "coding-agent: %d search block(s) did not match; applied the rest"
                   (length failures)))
        (coding-agent--begin-review
         src original proposed
         (lambda (apply?)
           (when apply?
             (coding-agent--apply-text src proposed original)))))))))

(defun coding-agent--dispatch (src prompt original)
  "Mark SRC busy and send PROMPT; ORIGINAL is the source text for the callback.
If the request cannot be dispatched (no provider/key, or gptel signals
synchronously) the busy flag is cleared and the error re-signalled, so SRC is
never left stuck as \"in progress\"."
  (coding-agent--set-busy src t)
  (condition-case err
      (coding-agent--request prompt
        :stream nil
        :callback (coding-agent--single-callback src original))
    ((error quit)
     (coding-agent--set-busy src nil)
     (signal (car err) (cdr err)))))

(defun coding-agent-run (instruction)
  "Send INSTRUCTION about the current source buffer to the LLM."
  (interactive "sInstruction: ")
  (coding-agent--ensure-not-busy)
  (let ((file (buffer-file-name)))
    (when (and file (not (coding-agent--text-file-p file)))
      (user-error "coding-agent: %s looks like a binary file"
                  (file-name-nondirectory file))))
  (let* ((src    (current-buffer))
         (lang   (coding-agent--buffer-language src))
         (source (buffer-substring-no-properties (point-min) (point-max)))
         (prompt (coding-agent--build-prompt lang source instruction)))
    (message "coding-agent: sending %s buffer to %s (%s)..."
             lang (coding-agent--provider-label) coding-agent-model)
    (coding-agent--dispatch src prompt source)))

(defun coding-agent-refine (instruction)
  "Send a follow-up INSTRUCTION using the last proposal as the new source.
This gives iterative refinement without re-typing the whole request."
  (interactive "sRefine instruction: ")
  (coding-agent--ensure-not-busy)
  (let* ((src  (current-buffer))
         (base (or coding-agent--proposed-text
                   (buffer-substring-no-properties (point-min) (point-max))))
         (lang (coding-agent--buffer-language src))
         (prompt (coding-agent--build-prompt lang base instruction)))
    (message "coding-agent: refining with %s (%s)..."
             (coding-agent--provider-label) coding-agent-model)
    (coding-agent--dispatch src prompt base)))

;; ---------------------------------------------------------------------------
;; Multi-file (project) agent
;; ---------------------------------------------------------------------------

(defun coding-agent--find-or-make-file-buffer (abs)
  "Return a buffer visiting ABS, creating one (with a real major mode) if new."
  (or (find-buffer-visiting abs)
      (if (file-exists-p abs)
          (find-file-noselect abs)
        (let ((buf (create-file-buffer abs)))
          (with-current-buffer buf
            (set-visited-file-name abs t)
            (set-auto-mode))
          buf))))

(defun coding-agent--project-review-queue (root pairs)
  "Review each (relative-path . body) in PAIRS under ROOT, in sequence.
The queue lives in a closure, so no global review state is needed."
  (let ((queue pairs))
    (cl-labels
        ((next ()
           (if (null queue)
               (message "coding-agent: project review complete")
             (let* ((pair     (pop queue))
                    (rel      (car pair))
                    (body     (cdr pair))
                    (abs      (expand-file-name rel root))
                    (buf      (coding-agent--find-or-make-file-buffer abs))
                    (original (with-current-buffer buf
                                (buffer-substring-no-properties
                                 (point-min) (point-max))))
                    (edit     (coding-agent--apply-edits-to-string original body))
                    (proposed (plist-get edit :text))
                    (failures (plist-get edit :failures)))
               (when failures
                 (message "coding-agent: %s: %d search block(s) did not match"
                          rel (length failures)))
               (message "coding-agent: reviewing %s" rel)
               (coding-agent--begin-review
                buf original proposed
                (lambda (apply?)
                  (when apply?
                    (coding-agent--apply-text buf proposed original))
                  (next)))))))
      (next))))

(defun coding-agent--project-callback (root)
  "Return a gptel callback for a project run rooted at ROOT."
  (lambda (response info)
    (cond
     ((null response) (coding-agent--report-error info))
     ((not (stringp response)) nil)
     (t
      (coding-agent--stash-raw response "*coding-agent-project-raw*")
      (let ((pairs (coding-agent--parse-multi-file-response response)))
        (if (null pairs)
            (message "coding-agent: no FILE: blocks (see *coding-agent-project-raw*)")
          (message "coding-agent: %d file(s) proposed; starting review..."
                   (length pairs))
          (coding-agent--project-review-queue root pairs)))))))

(defun coding-agent-run-project (instruction)
  "Send INSTRUCTION about the whole project to the LLM.
Collects source files under `default-directory' matching the current
buffer's language, warns about size, and reviews each returned file."
  (interactive "sProject instruction: ")
  (let* ((root  (expand-file-name default-directory))
         (lang  (coding-agent--buffer-language (current-buffer)))
         (files (coding-agent--collect-project-files root lang)))
    (unless files
      (user-error "coding-agent: no %s source files found under %s" lang root))
    (let ((total (apply #'+ (mapcar (lambda (f)
                                      (or (file-attribute-size (file-attributes f)) 0))
                                    files))))
      (when (and (> total coding-agent-project-max-bytes)
                 (not (yes-or-no-p
                       (format "Project is %s across %d files (cap %s); send anyway? "
                               (file-size-human-readable total) (length files)
                               (file-size-human-readable coding-agent-project-max-bytes)))))
        (user-error "coding-agent: aborted (project too large)"))
      (when (and coding-agent-confirm-project-send
                 (not (yes-or-no-p
                       (format "Send %d %s file(s) (%s) to the LLM? "
                               (length files) lang (file-size-human-readable total)))))
        (user-error "coding-agent: aborted"))
      (setq coding-agent--project-root root)
      (let* ((files-alist
              (mapcar (lambda (abs)
                        (cons (file-relative-name abs root)
                              (coding-agent--file-contents abs)))
                      files))
             (prompt (coding-agent--build-project-prompt lang files-alist instruction)))
        (message "coding-agent: sending %d file(s) (%s) to the LLM..."
                 (length files) (file-size-human-readable total))
        (coding-agent--request prompt
          :stream nil
          :callback (coding-agent--project-callback root))))))

;; ---------------------------------------------------------------------------
;; Raw chat helpers (use real gptel entry points, not the nonexistent
;; `gptel-chat')
;; ---------------------------------------------------------------------------

(defun coding-agent-open-chat ()
  "Open (or switch to) a gptel chat buffer on the active backend."
  (interactive)
  (coding-agent--ensure-key)
  (coding-agent--ensure-model-registered)
  (let ((gptel-backend coding-agent-backend)
        (gptel-model coding-agent-model))
    (pop-to-buffer (gptel "*coding-agent-chat*"))))

(defun coding-agent-send-region-or-buffer ()
  "Send the region, or the whole buffer, to the LLM and show the reply."
  (interactive)
  (let ((text (if (use-region-p)
                  (buffer-substring-no-properties (region-beginning) (region-end))
                (buffer-substring-no-properties (point-min) (point-max)))))
    (coding-agent--request text
      :stream nil
      :callback
      (lambda (response info)
        (if (stringp response)
            (progn
              (coding-agent--stash-raw response "*coding-agent-chat-output*")
              (display-buffer "*coding-agent-chat-output*"))
          (when (null response) (coding-agent--report-error info)))))))

;; ---------------------------------------------------------------------------
;; Evaluate / syntax-check the current buffer
;; ---------------------------------------------------------------------------

(defun coding-agent-eval-buffer-for-language ()
  "Evaluate or syntax-check the current buffer for its language."
  (interactive)
  (let ((lang (coding-agent-detect-language (current-buffer))))
    (pcase lang
      ("python"
       (if (fboundp 'python-shell-send-buffer)
           (python-shell-send-buffer)
         (message "coding-agent: python-mode not available")))
      ("common-lisp"
       (if (fboundp 'slime-compile-and-load-file)
           (slime-compile-and-load-file)
         (message "coding-agent: slime not available")))
      ("clojure"
       (if (fboundp 'cider-load-buffer)
           (cider-load-buffer)
         (message "coding-agent: cider not available")))
      ("emacs-lisp"
       (eval-buffer)
       (message "coding-agent: buffer evaluated"))
      (_
       (if (coding-agent--syntax-ok-p (current-buffer))
           (message "coding-agent: no evaluator for %s (delimiters look balanced)" lang)
         (message "coding-agent: unbalanced delimiters in buffer"))))))

;; ---------------------------------------------------------------------------
;; Help and transient menu
;; ---------------------------------------------------------------------------

(defun coding-agent-help ()
  "Show a short coding-agent cheatsheet."
  (interactive)
  (message
   (concat
    "coding-agent\n"
    "  C-c a r  run (file)      C-c a p  run (project)\n"
    "  C-c a f  refine last     C-c a a  apply proposed\n"
    "  C-c a e  eval/check      C-c a .  menu   C-c a h  help\n"
    "  C-c a m  change model/provider   C-c a g  reset busy flag\n"
    "  C-c l r  send region     C-c l c  chat buffer\n"
    "Flow: run -> read *coding-agent-diff* -> answer y to apply (or M-x coding-agent-apply-proposed)")))

(transient-define-prefix coding-agent-dispatch ()
  "Coding-agent command menu."
  [["Edit"
    ("r" "Run on file"      coding-agent-run)
    ("p" "Run on project"   coding-agent-run-project)
    ("f" "Refine last"      coding-agent-refine)
    ("a" "Apply proposed"   coding-agent-apply-proposed)]
   ["Other"
    ("e" "Eval / check buffer"    coding-agent-eval-buffer-for-language)
    ("m" "Model / provider"       coding-agent-model-change)
    ("g" "Reset busy flag"        coding-agent-reset)
    ("c" "Chat: region/buffer"    coding-agent-send-region-or-buffer)
    ("C" "Open chat buffer"       coding-agent-open-chat)
    ("h" "Help"                   coding-agent-help)]])

;; ---------------------------------------------------------------------------
;; Keymap and minor mode (no global bindings until the mode is enabled)
;; ---------------------------------------------------------------------------

(defvar coding-agent-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'coding-agent-run)
    (define-key map (kbd "p") #'coding-agent-run-project)
    (define-key map (kbd "f") #'coding-agent-refine)
    (define-key map (kbd "a") #'coding-agent-apply-proposed)
    (define-key map (kbd "e") #'coding-agent-eval-buffer-for-language)
    (define-key map (kbd "m") #'coding-agent-model-change)
    (define-key map (kbd "g") #'coding-agent-reset)
    (define-key map (kbd "h") #'coding-agent-help)
    (define-key map (kbd ".") #'coding-agent-dispatch)
    map)
  "Keymap bound under the \"C-c a\" prefix by `coding-agent-mode'.")
(fset 'coding-agent-command-map coding-agent-command-map)

(defvar coding-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a") 'coding-agent-command-map)
    (define-key map (kbd "C-c l r") #'coding-agent-send-region-or-buffer)
    (define-key map (kbd "C-c l c") #'coding-agent-open-chat)
    map)
  "Keymap for `coding-agent-mode'.")

;;;###autoload
(define-minor-mode coding-agent-mode
  "Minor mode providing coding-agent keybindings."
  :lighter " CA"
  :keymap coding-agent-mode-map)

(defun coding-agent--maybe-enable ()
  "Turn on `coding-agent-mode' in the current buffer."
  (coding-agent-mode 1))

;;;###autoload
(define-globalized-minor-mode global-coding-agent-mode
  coding-agent-mode coding-agent--maybe-enable)

(provide 'coding-agent)
;;; coding-agent.el ends here
