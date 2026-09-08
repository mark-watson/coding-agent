;;; coding-agent.el --- LLM-powered coding agent using gptel -*- lexical-binding: t; -*-

;; Author: Mark Watson
;; Version: 0.3.0
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
;; A third, agentic scope is available with `coding-agent-agent-run' (C-c a R):
;; the model drives a multi-turn session using tools (read_file, list_dir,
;; grep, run_shell with a whitelist, and propose_edit with a per-file diff
;; review) instead of receiving files up front.
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
;; Reviews offer yes/no/skip: answering "skip" asks for a one-line reason that
;; is folded into the next request so the model adjusts instead of blindly
;; retrying.  When `coding-agent-check-command' names a Makefile target
;; (e.g. "check"), it runs after every applied edit and its output is shown;
;; failures can be fed back to the model as a follow-up.
;;
;; This file configures its own gptel backend.  It defaults to Fireworks.ai
;; (model `accounts/fireworks/models/deepseek-v4-flash'), reading the API key
;; from the FIREWORKS_API_KEY environment variable, and can switch at runtime
;; between Fireworks.ai, a local Ollama server, and the Anthropic API with
;; `coding-agent-model-change' (C-c a m).  Additional OpenAI-compatible or
;; Ollama-style providers can be declared without any elisp in
;; ~/.coding_harness.json plus a per-project .coding_agent_harness.json
;; override (see `coding-agent-reload-harness-config').  A provider whose
;; API-key environment variable is unset is not offered.  It does not enable
;; its keybindings on load; call `(global-coding-agent-mode 1)' in your init
;; (see `coding-agent-config.el' for an example).
;;
;; Key commands (active when `coding-agent-mode' is on):
;;   C-c a r  coding-agent-run                    edit the current file
;;   C-c a p  coding-agent-run-project            edit across the project
;;   C-c a R  coding-agent-agent-run              agentic session with tools
;;   C-c a f  coding-agent-refine                 follow-up on the last result
;;   C-c a a  coding-agent-apply-proposed         apply the stashed proposal
;;   C-c a e  coding-agent-eval-buffer-for-language
;;   C-c a .  coding-agent-dispatch               transient menu
;;   C-c a m  coding-agent-model-change           switch provider/model
;;   C-c a g  coding-agent-reset                  clear a stuck in-progress flag
;;   C-c a h  coding-agent-help
;;   C-c a /  coding-agent-load-skill             load a ~/.agents skill
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
(require 'json)
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

(defcustom coding-agent-dry-run nil
  "When non-nil, show diffs but never modify buffers or files."
  :type 'boolean)

(defcustom coding-agent-auto-approve nil
  "When non-nil, apply proposals without asking (the diff is still shown).
The post-apply check from `coding-agent-check-command' still runs."
  :type 'boolean)

(defcustom coding-agent-check-command "check"
  "Name of a Makefile target run after an applied edit, or nil to disable.
The command is run as \"make TARGET\" in the project root.  Its output
(truncated to `coding-agent-check-max-output' characters) is shown and,
on failure, can be fed back to the model as a follow-up."
  :type '(choice (const :tag "Disabled" nil) string))

(defcustom coding-agent-check-max-output 2000
  "Maximum characters of `coding-agent-check-command' output to keep."
  :type 'integer)

(defcustom coding-agent-review-save-window-config t
  "When non-nil, restore the window layout after a diff review finishes."
  :type 'boolean)

(defcustom coding-agent-skills-directory "~/.agents/skills"
  "Directory containing skill subdirectories, each holding a SKILL.md file.
Skills are shared with command-line coding agents that use the same layout."
  :type 'directory)

(defcustom coding-agent-search-engine 'brave
  "Web search backend used by `coding-agent-enrich-with-search': brave or exa."
  :type '(choice (const brave) (const exa)))

(defcustom coding-agent-shell-command-whitelist
  '("make" "ls" "pwd" "cat" "rg" "grep" "git" "uv")
  "Commands the agentic run_shell tool is allowed to execute."
  :type '(repeat string))

(defcustom coding-agent-agent-max-iterations 20
  "Upper bound on model round-trips in a single agentic session."
  :type 'integer)

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
  '(accounts/fireworks/models/deepseek-v4-flash
    accounts/fireworks/models/deepseek-v4-flash-0731)
  "Models offered for the Fireworks.ai provider.")

(defvar coding-agent-ollama-local-models
  '(qwen3:latest llama3.2:latest deepseek-r1:latest
    nemotron-3.5-lightning:30b-mlx)
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
or that environment variable is set.  Additional providers from
`~/.coding_harness.json' / project-local `.coding_agent_harness.json'
are appended here by `coding-agent-load-harness-config'.")

;; Declared here (defined below) so the config loader compiles cleanly.
(defvar coding-agent-model)
(defvar coding-agent-backend)
(defvar coding-agent-provider)

;; ---------------------------------------------------------------------------
;; JSON harness config (~/.coding_harness.json + project-local override)
;; Format (all sections optional):
;;   { "default_provider": "mlx",
;;     "providers": { "<name>": { "type": "openai" | "mlx" | "ollama",
;;                                "endpoint": "https://.../v1/chat/completions",
;;                                "api_key_env": "SOME_KEY",   (optional)
;;                                "model": "model-id",
;;                                "thinking": false,           (mlx: disable reasoning)
;;                                "generation": {"temperature": 0.6,
;;                                               "max_tokens": 32768} } } }
;; "type": "openai" and "mlx" map to an OpenAI-compatible gptel backend (mlx
;; serves /v1/chat/completions); the legacy "ollama" maps to gptel's native
;; Ollama backend (/api/chat).
;; Project-local entries deep-merge over (and win against) the global file.
;; ---------------------------------------------------------------------------

(defun coding-agent--harness-config-files ()
  "Return (GLOBAL-FILE . LOCAL-FILE) paths for the harness config."
  (cons (expand-file-name "~/.coding_harness.json")
        (expand-file-name ".coding_agent_harness.json" default-directory)))

(defun coding-agent--read-json-object (file)
  "Return FILE parsed as a JSON object (alist), or nil if missing/invalid."
  (when (file-readable-p file)
    (condition-case nil
        (let ((v (json-read-file file)))
          (and (listp v) v))
      (error nil))))

(defun coding-agent--json-merge (global local)
  "Recursively merge alists GLOBAL and LOCAL; LOCAL wins on conflicts.
Non-alist values are replaced wholesale."
  (if (not (and (listp global) (listp local)))
      (or local global)
    (let ((result (copy-alist global)))
      (dolist (pair local)
        (let* ((key (car pair))
               (prev (assq key result)))
          (setq result
                (if (and prev (listp (cdr prev)) (listp (cdr pair)))
                    (cons (cons key (coding-agent--json-merge (cdr prev) (cdr pair)))
                          (assq-delete-all key result))
                  (cons pair (assq-delete-all key result))))))
      result)))

(defun coding-agent--json-string (obj key)
  "Return the string value at KEY in alist OBJ, or nil."
  (let ((v (cdr (assq key obj))))
    (and (stringp v) (not (string-empty-p v)) v)))

(defun coding-agent--endpoint-to-host (endpoint)
  "Return \"host[:port]\" for gptel from an http(s) ENDPOINT URL."
  (when endpoint
    (let* ((s (string-remove-suffix "/" endpoint))
           (s (replace-regexp-in-string "\\`https?://" "" s)))
      (car (split-string s "/")))))

(defun coding-agent--endpoint-to-path (endpoint)
  "Return the URL path component of ENDPOINT, with leading \"/\"."
  (when endpoint
    (let ((u (url-generic-parse-url endpoint)))
      (and (url-filename u)
           (if (string-prefix-p "/" (url-filename u))
               (url-filename u)
             (concat "/" (url-filename u)))))))

(defun coding-agent--endpoint-to-protocol (endpoint)
  "Return \"http\" or \"https\" from ENDPOINT, defaulting to \"http\"."
  (if (and endpoint
           (string-prefix-p "https" endpoint))
      "https"
    "http"))

(defun coding-agent--thinking-off-p (thinking)
  "Return non-nil when the profile's THINKING field requests thinking off.
THINKING is the raw JSON value of the \"thinking\" key: JSON false arrives
as :json-false; accept the string \"false\" too."
  (or (eq thinking :json-false)
      (equal thinking "false")))

(defun coding-agent--provider-from-profile (name profile)
  "Build a provider entry from a JSON provider PROFILE named NAME.
Return (KEY :label ... :backend ... :models ... :env ...), or nil."
  (let* ((type     (downcase (or (coding-agent--json-string profile 'type) "openai")))
         (endpoint (coding-agent--json-string profile 'endpoint))
         (model    (coding-agent--json-string profile 'model))
         (key-env  (coding-agent--json-string profile 'api_key_env))
         (gen      (cdr (assq 'generation profile)))
         (max-tok  (and (listp gen) (cdr (assq 'max_tokens gen))))
         (temp     (and (listp gen) (cdr (assq 'temperature gen))))
         (thinking (cdr (assq 'thinking profile)))
         (models   (list (intern (or model "default"))))
         (key      (intern name)))
    (cond
     ;; Native Ollama protocol endpoint (/api/chat).
     ((string= type "ollama")
      `(,key :label ,name
        :backend ,(gptel-make-ollama (copy-sequence name)
                    :host (or (coding-agent--endpoint-to-host endpoint)
                              "localhost:11434")
                    :stream t
                    :models models
                    :request-params `(:options (:num_ctx ,coding-agent-ollama-num-ctx)))
        :models ,models :env nil))
     ;; Local MLX server: OpenAI-compatible, endpoint path respected, no key.
     ((string= type "mlx")
      (let ((host (or (coding-agent--endpoint-to-host endpoint)
                      "localhost:11434"))
            (path (or (coding-agent--endpoint-to-path endpoint)
                      "/v1/chat/completions"))
            (proto (coding-agent--endpoint-to-protocol endpoint))
            (req  (append (when (numberp temp) `(:temperature ,temp))
                          (when (integerp max-tok) `(:max_tokens ,max-tok))
                          (when (coding-agent--thinking-off-p thinking)
                            `(:chat_template_kwargs
                              (:enable_thinking :json-false))))))
        `(,key :label ,name
          :backend ,(apply #'gptel-make-openai (copy-sequence name)
                           :host host :endpoint path :protocol proto
                           :stream t :models models
                           (when req (list :request-params req)))
          :models ,models :env nil)))
     ;; OpenAI-compatible REST endpoint (Fireworks and compatible servers).
     (t
      (let ((host (or (coding-agent--endpoint-to-host endpoint)
                      "api.fireworks.ai"))
            (path (or (coding-agent--endpoint-to-path endpoint)
                      "/inference/v1/chat/completions"))
            (req  (append (when (numberp temp) `(:temperature ,temp))
                          (when (integerp max-tok) `(:max_tokens ,max-tok)))))
        (unless key-env
          (setq key-env "FIREWORKS_API_KEY")) ; profile type openai w/o key: reuse default var
        `(,key :label ,name
          :backend ,(apply #'gptel-make-openai (copy-sequence name)
                           :host host :endpoint path :stream t :models models
                           (append (list :key (coding-agent--env-key key-env))
                                   (when req (list :request-params req))))
          :models ,models :env ,key-env))))))

(defun coding-agent-load-harness-config ()
  "Load provider profiles from the global and project-local JSON config.
Previously loaded profile providers are replaced, so re-run this after
editing the files (or switching projects).  Profiles are appended to
`coding-agent--providers'; when the merged config names a
\"default_provider\" profile, it is activated.  Return profile names."
  (interactive)
  (let* ((files (coding-agent--harness-config-files))
         (global (coding-agent--read-json-object (car files)))
         (local  (coding-agent--read-json-object (cdr files)))
         (names '()))
    ;; Drop previously-loaded profile providers (tagged :profile t).
    (setq coding-agent--providers
          (cl-remove-if (lambda (e) (plist-get (cdr e) :profile))
                        coding-agent--providers))
    (when-let* ((merged (and (or global local)
                             (coding-agent--json-merge global local)))
                (profiles (cdr (assq 'providers merged))))
      (dolist (entry profiles)
        (let ((prov (coding-agent--provider-from-profile
                     (symbol-name (car entry)) (cdr entry))))
          (when prov
            (plist-put (cdr prov) :profile t)
            (push (car prov) names)
            (setq coding-agent--providers
                  (append coding-agent--providers (list prov))))))
      (let* ((default (coding-agent--json-string merged 'default_provider))
             (dkey    (and default (intern default))))
        (when (and dkey (coding-agent--provider-available-p dkey))
          (let ((p (coding-agent--provider dkey)))
            (setq coding-agent-provider dkey
                  coding-agent-backend  (plist-get p :backend)
                  coding-agent-model    (or (car (plist-get p :models))
                                            coding-agent-model))))))
    (when (called-interactively-p 'any)
      (message "coding-agent: harness profiles loaded: %s"
               (if names (mapconcat #'symbol-name (nreverse names) ", ") "none")))
    (nreverse names)))

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

(defun coding-agent--hidden-file-p (name)
  "Return non-nil when NAME (a basename) is a dotfile or Emacs-internal file."
  (or (string-prefix-p "." name)
      (string-suffix-p "~" name)
      (and (string-prefix-p "#" name) (string-suffix-p "#" name))
      (string-suffix-p ".coding-agent.bak" name)))

(defun coding-agent--extensions-for-language (lang)
  "Return the list of file extensions appropriate for LANG."
  (cdr (assoc lang coding-agent--language-extensions)))

;; ---------------------------------------------------------------------------
;; Prompt construction
;; ---------------------------------------------------------------------------

(defvar-local coding-agent--skills nil
  "Alist of (NAME . CONTENT) of skills loaded into this buffer's requests.")

(defvar coding-agent--search-results nil
  "Most recent search block to prepend to the next prompt; cleared after use.")

(defun coding-agent--skill-preamble ()
  "Concatenated contents of loaded skills, or nil."
  (when (and coding-agent--skills (listp coding-agent--skills))
    (mapconcat (lambda (s)
                 (format "The user has loaded the skill '%s'.  Use it as an authoritative reference.\n\n%s"
                         (car s) (cdr s)))
               coding-agent--skills "\n\n---\n\n")))

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
  "Build a single-file LLM prompt for LANGUAGE, SOURCE and INSTRUCTION.
Loaded skills and `coding-agent--search-results' are prepended when set."
  (let ((skills (coding-agent--skill-preamble))
        (search (coding-agent--search-results)))
    (concat
     (when skills (concat skills "\n\n"))
     (when search (concat search "\n\n"))
     (format "You are an expert %s programmer.

INSTRUCTION: %s

%s

CURRENT FILE:
%s"
             language instruction coding-agent--protocol-help source))))

(defun coding-agent--build-project-prompt (language files-alist instruction)
  "Build a multi-file LLM prompt for LANGUAGE.
FILES-ALIST is a list of (relative-path . content).  INSTRUCTION is the request.
Loaded skills and `coding-agent--search-results' are prepended when set."
  (let ((files-block
         (mapconcat (lambda (pair)
                      (format "FILE: %s\n%s\nEND_FILE" (car pair) (cdr pair)))
                    files-alist "\n\n"))
        (skills (coding-agent--skill-preamble))
        (search (coding-agent--search-results)))
    (concat
     (when skills (concat skills "\n\n"))
     (when search (concat search "\n\n"))
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
             language instruction files-block))))

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

(defconst coding-agent--review-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "S") #'coding-agent--review-skip)
    map)
  "Extra keys active in `*coding-agent-diff*' during a review.")

(define-minor-mode coding-agent--review-mode
  "Minor mode active in the review diff buffer; adds S for skip."
  :lighter " CA-review"
  :keymap coding-agent--review-map)

(defvar coding-agent--review-skip-fn nil
  "Function run by `coding-agent--review-skip' in the review buffer.")

(defun coding-agent--review-mode-setup (buffer)
  "Enable the review minor mode in BUFFER with a skip key."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local coding-agent--review-skip-fn
                  (lambda (reason) (throw 'skip (cons 'skip reason))))
      (coding-agent--review-mode 1))))

(defun coding-agent--review-mode-teardown (buffer)
  "Disable the review minor mode in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (coding-agent--review-mode -1))))

(defun coding-agent--review-skip ()
  "Skip the proposed change, asking for a one-line reason for the model."
  (interactive)
  (when (and (eq (current-buffer) (get-buffer "*coding-agent-diff*"))
             coding-agent--review-skip-fn)
    (funcall coding-agent--review-skip-fn (read-string "Reason (sent to model): "))))

(defun coding-agent--review-prompt (prompt)
  "PROMPT for the review outcome.
Return one of `apply', `no' or (`skip' . REASON)."
  (let ((key (read-key
              (propertize (concat prompt "[y]es / [n]o / [s]kip with reason ")
                          'face 'minibuffer-prompt))))
    (pcase key
      ((or ?y ?\r) 'apply)
      ((or ?n ?\e) 'no)
      (?s (cons 'skip (read-string "Reason (sent to model): ")))
      (_ (message "coding-agent: please answer y, n or s")
         (sit-for 1)
         (coding-agent--review-prompt prompt)))))

(defun coding-agent--review (src original proposed after-fn)
  "Show a diff of ORIGINAL vs PROPOSED for SRC, then ask whether to apply.
AFTER-FN receives one of `apply', `no' or (`skip' . REASON).  The diff is
shown in the reusable `*coding-agent-diff*' buffer; with
`coding-agent-review-save-window-config' the window layout is restored
afterwards, and with `coding-agent-auto-approve' the prompt is skipped."
  (let ((diff-buf (coding-agent--diff-strings original proposed
                                              "*coding-agent-diff*"))
        (winconf (and coding-agent-review-save-window-config
                      (current-window-configuration))))
    (display-buffer diff-buf)
    (coding-agent--review-mode-setup diff-buf)
    (unwind-protect
        (let ((outcome
               (cond
                ((not (buffer-live-p src)) 'no)
                (coding-agent-auto-approve
                 (message "coding-agent: auto-approving changes to %s"
                          (buffer-name src))
                 'apply)
                (coding-agent-dry-run 'no)
                (t
                 (catch 'skip
                   (coding-agent--review-prompt
                    (format "Apply proposed changes to %s? "
                            (buffer-name src))))))))
          (funcall after-fn outcome))
      (coding-agent--review-mode-teardown diff-buf)
      (when winconf (set-window-configuration winconf)))))

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

;; ---------------------------------------------------------------------------
;; Post-apply test gate (`make check') and feedback plumbing
;; ---------------------------------------------------------------------------

(defvar coding-agent--pending-feedback nil
  "Lines (skip reasons, check failures) folded into the next LLM request.")

(defun coding-agent--add-feedback (text)
  "Queue TEXT to be prepended to the next request's instruction."
  (when (and text (not (string-empty-p text)))
    (push text coding-agent--pending-feedback)))

(defun coding-agent--consume-feedback ()
  "Return queued feedback as one block of text, clearing the queue."
  (prog1 (when coding-agent--pending-feedback
           (concat "Feedback from the previous attempt:\n"
                   (mapconcat #'identity
                              (nreverse coding-agent--pending-feedback) "\n")))
    (setq coding-agent--pending-feedback nil)))

(defun coding-agent--truncate (text max)
  "Return TEXT truncated to MAX characters with a note when cut."
  (if (and text (> (length text) max))
      (concat (substring text 0 max)
              (format "\n... (truncated, %d total chars)" (length text)))
    (or text "")))

(defun coding-agent--project-check-root (near)
  "Return a directory around NEAR containing a Makefile with a check target."
  (when coding-agent-check-command
    (let ((dir (locate-dominating-file
                (or (and near (buffer-file-name near)) default-directory)
                (lambda (d)
                  (let ((mk (expand-file-name "Makefile" d)))
                    (and (file-exists-p mk)
                         (with-temp-buffer
                           (insert-file-contents mk nil 0 50000)
                           (goto-char (point-min))
                           (re-search-forward
                            (concat "^" (regexp-quote coding-agent-check-command) ":")
                            nil t))))))))
      dir)))

(defun coding-agent--run-check (buffer)
  "Run `make check' near BUFFER; offer to stash failures as model feedback.
Return a status string, or nil when no check ran."
  (let ((root (coding-agent--project-check-root
               (and (bufferp buffer) buffer))))
    (if (not (and root (not coding-agent-dry-run)))
        "no check configured"
      (let* ((default-directory root)
             (out (with-temp-buffer
                    (let ((code (process-file "make" nil t nil
                                              coding-agent-check-command)))
                      (cons code (buffer-string)))))
             (code (car out))
             (text (coding-agent--truncate (cdr out)
                                           coding-agent-check-max-output)))
        (if (zerop code)
            "make check passed"
          (coding-agent--stash-raw
           (format "make %s failed (exit %d) in %s:\n\n%s"
                   coding-agent-check-command code root text)
           "*coding-agent-check*")
          (when (y-or-n-p "make check FAILED; feed the output back to the model? ")
            (coding-agent--add-feedback
             (format "After your edit, `make %s` FAILED with this output:\n%s"
                     coding-agent-check-command text)))
          (format "make check FAILED (exit %d) -- see *coding-agent-check*" code))))))

(defun coding-agent--apply-text (buffer text &optional original)
  "Replace BUFFER contents with TEXT.
No-op when TEXT equals the current buffer contents.  When ORIGINAL is
given, guard against a suspiciously small (truncated) whole-file
replacement; if `coding-agent-check-after-apply', verify delimiters
afterwards; and run the `coding-agent-check-command' test gate.
Honors `coding-agent-dry-run' (never touches the buffer)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cond
       (coding-agent-dry-run
        (message "coding-agent: dry-run; %s left untouched" (buffer-name buffer)))
       ((and original (string= text
                               (buffer-substring-no-properties
                                (point-min) (point-max))))
        (message "coding-agent: no changes (proposal matches current buffer)"))
       (t
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
        (let ((status (coding-agent--run-check buffer)))
          (message "coding-agent: applied changes to %s (%s%s)"
                   (buffer-name buffer)
                   (if coding-agent-apply-saves-buffer "saved" "unsaved")
                   (if status (concat "; " status) ""))))))))

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

(defun coding-agent-toggle-dry-run ()
  "Toggle `coding-agent-dry-run': when on, proposals are shown but never applied."
  (interactive)
  (setq coding-agent-dry-run (not coding-agent-dry-run))
  (message "coding-agent: dry-run %s" (if coding-agent-dry-run "ON" "off")))

(defun coding-agent-toggle-auto-approve ()
  "Toggle `coding-agent-auto-approve': when on, proposals apply without asking."
  (interactive)
  (setq coding-agent-auto-approve (not coding-agent-auto-approve))
  (message "coding-agent: auto-approve %s" (if coding-agent-auto-approve "ON" "off")))

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
      (coding-agent--record-usage info)
      (coding-agent--history-push 'assistant response)
      (let* ((edit     (coding-agent--apply-edits-to-string original response))
             (proposed (plist-get edit :text))
             (failures (plist-get edit :failures)))
        (when failures
          (message "coding-agent: %d search block(s) did not match; applied the rest"
                   (length failures)))
        (coding-agent--begin-review
         src original proposed
         (lambda (outcome)
           (pcase outcome
             ('apply
              (unless coding-agent-dry-run
                (coding-agent--apply-text src proposed original)))
             (`(skip . ,reason)
              (coding-agent--add-feedback
               (format "The user skipped your previous proposal because: %s"
                       reason))
              (message "coding-agent: skipped; reason saved for the next refine"))
             (_
              (message "coding-agent: changes to %s not applied"
                       (buffer-name src)))))))))))

(defun coding-agent--dispatch (src prompt original)
  "Mark SRC busy and send PROMPT; ORIGINAL is the source text for the callback.
If the request cannot be dispatched (no provider/key, or gptel signals
synchronously) the busy flag is cleared and the error re-signalled, so SRC is
never left stuck as \"in progress\"."
  (coding-agent--set-busy src t)
  (coding-agent--history-push 'user prompt)
  (condition-case err
      (coding-agent--request prompt
        :stream nil
        :callback (coding-agent--single-callback src original))
    ((error quit)
     (coding-agent--set-busy src nil)
     (signal (car err) (cdr err)))))

(defun coding-agent-run (instruction)
  "Send INSTRUCTION about the current source buffer to the LLM.
With \\[universal-argument], first enrich the instruction with web
search results (`coding-agent-enrich-with-search')."
  (interactive "sInstruction: ")
  (coding-agent--ensure-not-busy)
  (let ((file (buffer-file-name)))
    (when file
      (unless (coding-agent--text-file-p file)
        (user-error "coding-agent: %s looks like a binary file"
                    (file-name-nondirectory file)))
      (when (coding-agent--hidden-file-p (file-name-nondirectory file))
        (user-error "coding-agent: refusing to send hidden/internal file %s"
                    (file-name-nondirectory file)))
      (when (coding-agent--secret-file-p file)
        (user-error "coding-agent: refusing to send secret-looking file %s"
                    (file-name-nondirectory file)))))
  (when (and current-prefix-arg
             (not (coding-agent-enrich-with-search)))
    (user-error "coding-agent: search enrichment failed"))
  (let* ((src    (current-buffer))
         (lang   (coding-agent--buffer-language src))
         (source (buffer-substring-no-properties (point-min) (point-max)))
         (fb     (coding-agent--consume-feedback))
         (instr  (if fb (concat instruction "\n\n" fb) instruction))
         (prompt (coding-agent--build-prompt lang source instr)))
    (message "coding-agent: sending %s buffer to %s (%s)..."
             lang (coding-agent--provider-label) coding-agent-model)
    (coding-agent--dispatch src prompt source)))

(defun coding-agent-refine (instruction)
  "Send a follow-up INSTRUCTION using the last proposal as the new source.
This gives iterative refinement without re-typing the whole request.
With \\[universal-argument], first enrich with web search results."
  (interactive "sRefine instruction: ")
  (coding-agent--ensure-not-busy)
  (when (and current-prefix-arg
             (not (coding-agent-enrich-with-search)))
    (user-error "coding-agent: search enrichment failed"))
  (let* ((src  (current-buffer))
         (base (or coding-agent--proposed-text
                   (buffer-substring-no-properties (point-min) (point-max))))
         (lang (coding-agent--buffer-language src))
         (fb   (coding-agent--consume-feedback))
         (instr (if fb (concat instruction "\n\n" fb) instruction))
         (prompt (coding-agent--build-prompt lang base instr)))
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
                 (lambda (outcome)
                   (pcase outcome
                     ('apply
                      (unless coding-agent-dry-run
                        (coding-agent--apply-text buf proposed original)))
                     (`(skip . ,reason)
                      (coding-agent--add-feedback
                       (format "For %s the user skipped your proposal: %s"
                               rel reason)))
                     (_ nil))
                   (next)))))))
       (next))))

(defun coding-agent--project-callback (root)
  "Return a gptel callback for a project run rooted at ROOT."
  (lambda (response info)
    (cond
     ((null response) (coding-agent--report-error info))
     ((not (stringp response)) nil)
     (t
      (coding-agent--record-usage info)
      (coding-agent--history-push 'assistant response)
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
buffer's language, warns about size, and reviews each returned file.
With \\[universal-argument], first enrich with web search results."
  (interactive "sProject instruction: ")
  (when (and current-prefix-arg
             (not (coding-agent-enrich-with-search)))
    (user-error "coding-agent: search enrichment failed"))
  (let* ((fb    (coding-agent--consume-feedback))
         (instruction (if fb (concat instruction "\n\n" fb) instruction))
         (root  (expand-file-name default-directory))
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
        (coding-agent--record-usage info)
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
;; Skills (~/.agents/skills/<name>/SKILL.md)
;; ---------------------------------------------------------------------------

(defun coding-agent--list-skills ()
  "Return names of skills in `coding-agent-skills-directory'."
  (let ((dir (expand-file-name coding-agent-skills-directory)))
    (when (file-directory-p dir)
      (cl-sort
       (cl-remove-if-not
        (lambda (name)
          (file-exists-p (expand-file-name (concat name "/SKILL.md") dir)))
        (directory-files dir nil "^[^.]" t))
       #'string<))))

(defun coding-agent--skill-description (name)
  "Return the `description:' line from skill NAME's SKILL.md, or nil."
  (let ((file (expand-file-name (concat name "/SKILL.md")
                                coding-agent-skills-directory)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file nil 0 2000)
        (goto-char (point-min))
        (when (looking-at "---\n")
          (when (re-search-forward "^description: *\\(.*\\)$" nil t)
            (string-trim (match-string 1))))))))

(defun coding-agent-clear-skills ()
  "Unload all skills from the current buffer."
  (interactive)
  (setq coding-agent--skills nil)
  (message "coding-agent: unloaded all skills for %s" (buffer-name)))

(defun coding-agent-load-skill (name)
  "Load the skill NAME (a directory under `coding-agent-skills-directory').
Its SKILL.md is prepended to future prompts from this buffer, and (in an
agentic session) a summary request is sent to prime the model."
  (interactive
   (list (completing-read "Skill: " (coding-agent--list-skills) nil t)))
  (let ((file (expand-file-name (concat name "/SKILL.md")
                                coding-agent-skills-directory)))
    (unless (file-exists-p file)
      (user-error "coding-agent: no such skill: %s" name))
    (let ((content (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string))))
      (if (assoc name coding-agent--skills)
          (setcdr (assoc name coding-agent--skills) content)
        (push (cons name content) coding-agent--skills))
      (coding-agent--history-push 'note (format "skill `%s' loaded" name))
      (message "coding-agent: loaded skill %s%s"
               name
               (let ((d (coding-agent--skill-description name)))
                 (if d (concat " -- " d) ""))))))

;; ---------------------------------------------------------------------------
;; Web search (Brave / Exa) -- synchronous, used to enrich the next prompt
;; ---------------------------------------------------------------------------

(defvar coding-agent-search-enabled nil
  "When non-nil, enrich every instruction with web search results.")

(defun coding-agent--search-results ()
  "Return (and clear) the pending search block, if any."
  (prog1 coding-agent--search-results
    (setq coding-agent--search-results nil)))

(defun coding-agent--brave-search (query n)
  "Return (URL . TITLE) search results for QUERY from Brave."
  (let ((key (getenv "BRAVE_SEARCH_API_KEY")))
    (unless (and key (not (string-empty-p key)))
      (user-error "coding-agent: BRAVE_SEARCH_API_KEY is not set"))
    (let* ((url (format "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"
                        (url-hexify-string query) n))
           (url-request-extra-headers
            `(("X-Subscription-Token" . ,key)
              ("Accept" . "application/json")))
           (buf (url-retrieve-synchronously url t nil 15)))
      (unless buf (error "Brave search request failed"))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "\n\n" nil t)
            (let* ((data (json-read))
                   (web  (cdr (assq 'web data)))
                   (rs   (cdr (assq 'results web))))
              (mapcar (lambda (r)
                        (list (cdr (assq 'url r))
                              (cdr (assq 'title r))
                              (cdr (assq 'description r))))
                      rs)))
        (kill-buffer buf)))))

(defun coding-agent--exa-search (query n)
  "Return (URL . TITLE . HIGHLIGHT) search results for QUERY from Exa."
  (let ((key (getenv "EXA_SEARCH_API_KEY")))
    (unless (and key (not (string-empty-p key)))
      (user-error "coding-agent: EXA_SEARCH_API_KEY is not set"))
    (let* ((url-request-method "POST")
           (url-request-extra-headers
            `(("Content-Type" . "application/json")
              ("Authorization" . ,(concat "Bearer " key))))
           (url-request-data
            (json-serialize
             `((query . ,query) (type . "auto") (numResults . ,n)
               (contents . ((highlights . t))))))
           (buf (url-retrieve-synchronously "https://api.exa.ai/search" t nil 20)))
      (unless buf (error "Exa search request failed"))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "\n\n" nil t)
            (let* ((data (json-read))
                   (rs   (cdr (assq 'results data))))
              (mapcar (lambda (r)
                        (let ((hl (cdr (assq 'highlights r))))
                          (list (cdr (assq 'url r))
                                (cdr (assq 'title r))
                                (if (and (vectorp hl) (> (length hl) 0))
                                    (aref hl 0) ""))))
                      rs)))
        (kill-buffer buf)))))

(defun coding-agent-enrich-with-search (&optional query)
  "Run a web search for QUERY (default: read from minibuffer).
The results are stashed and prepended to the next instruction sent via
`coding-agent-run', `coding-agent-refine' or `coding-agent-run-project'.
Those commands call this when given a prefix argument."
  (interactive)
  (let* ((q (or query (read-string "Search query: ")))
         (results
          (condition-case err
              (if (eq coding-agent-search-engine 'exa)
                  (coding-agent--exa-search q 5)
                (coding-agent--brave-search q 5))
            (error (message "coding-agent: search failed: %s"
                            (error-message-string err))
                   nil))))
    (when results
      (setq coding-agent--search-results
            (concat (format "[Web search results for: %s]\n" q)
                    (mapconcat
                     (lambda (r) (format "- %s\n  %s\n  %s"
                                         (nth 1 r) (nth 0 r) (or (nth 2 r) "")))
                     results "\n")
                    "\n---"))
      (when (called-interactively-p 'any)
        (message "coding-agent: search results ready (%d hits); they enrich the next request"
                 (length results)))
      t)))

(defun coding-agent-toggle-search ()
  "Toggle enriching every instruction with web search results."
  (interactive)
  (setq coding-agent-search-enabled (not coding-agent-search-enabled))
  (message "coding-agent: web search %s (engine: %s)"
           (if coding-agent-search-enabled "ON" "off")
           coding-agent-search-engine))

;; ---------------------------------------------------------------------------
;; Session usage statistics
;; ---------------------------------------------------------------------------

(defvar coding-agent--usage (list :prompt 0 :completion 0)
  "Cumulative token counts reported by providers this session.")

(defun coding-agent--record-usage (info)
  "Accumulate token usage from gptel's INFO plist, if present."
  (let* ((data (plist-get info :data))
         (usage (and (listp data) (cdr (assq 'usage data)))))
    (when usage
      (cl-incf (plist-get coding-agent--usage :prompt)
               (or (cdr (assq 'prompt_tokens usage)) 0))
      (cl-incf (plist-get coding-agent--usage :completion)
               (or (cdr (assq 'completion_tokens usage)) 0)))))

(defun coding-agent-session-usage ()
  "Show token usage accumulated this session."
  (interactive)
  (let ((inhibit-read-only nil))
    (message "coding-agent session tokens: %d prompt, %d completion, %d total"
             (plist-get coding-agent--usage :prompt)
             (plist-get coding-agent--usage :completion)
             (+ (plist-get coding-agent--usage :prompt)
                (plist-get coding-agent--usage :completion)))))

;; ---------------------------------------------------------------------------
;; Agentic mode: gptel tool use
;; The model drives a multi-turn session with five tools (read_file,
;; list_dir, grep, run_shell, propose_edit).  All tool errors are converted
;; to strings so a weak model gets feedback instead of crashing the loop.
;; The agentic system prompt, repetition guard and diff review mirror the
;; companion Racket command-line agent (racket-coding-agent).
;; ---------------------------------------------------------------------------

(defvar coding-agent--agent-session nil
  "Plist holding the state of the in-flight agentic session, or nil.
Keys: :buffer :root :iterations :signatures.")

(defun coding-agent--agent-busy-p ()
  "Return non-nil when an agentic session is running."
  (and coding-agent--agent-session t))

(defconst coding-agent--agent-system-template
  "You are an interactive coding assistant working in the directory {root}.

Rules:
- Use read_file, list_dir and grep to understand the code BEFORE proposing edits.
- To EDIT an existing file: read_file it first, then pass its exact current
  contents as \"old\" to propose_edit.
- To CREATE a new file: call propose_edit with the empty string \"\" as \"old\".
- One file per propose_edit call.  Keep diffs small and focused.
- If the user rejects an edit or the check command fails, ask for
  clarification or try a different approach instead of blindly retrying.
- run_shell only accepts whitelisted commands: {whitelist}.
- When you are done, reply with a short natural-language summary of what changed."
  "System prompt template for `coding-agent-agent-run'.")

(defun coding-agent--agent-system-prompt ()
  "Build the system prompt for the current agentic session."
  (let ((root (or (plist-get coding-agent--agent-session :root)
                  default-directory)))
    (replace-regexp-in-string
     (regexp-quote "{root}") root
     (replace-regexp-in-string
      (regexp-quote "{whitelist}")
      (mapconcat #'identity coding-agent-shell-command-whitelist ", ")
      coding-agent--agent-system-template t t)
     t t)))

;; -- Tool function bodies --------------------------------------------------

(defun coding-agent--tool-path (relpath)
  "Resolve RELPATH against the session root; error if it escapes."
  (let* ((root (or (plist-get coding-agent--agent-session :root)
                   default-directory))
         (abs  (expand-file-name relpath root)))
    (unless (or (string-prefix-p (file-name-as-directory root) abs)
                (string= abs (directory-file-name root)))
      (error "coding-agent: refusing path outside the project root"))
    abs))

(defun coding-agent--tool-read-file (relpath)
  "Read the file RELPATH under the project root and return its contents."
  (condition-case err
      (let* ((abs (coding-agent--tool-path relpath))
             (base (file-name-nondirectory abs)))
        (cond
         ((coding-agent--hidden-file-p base)
          (format "Error: refusing to read hidden/internal file: %s" relpath))
         ((coding-agent--secret-file-p abs)
          (format "Error: refusing to read secret-looking file: %s" relpath))
         (t (with-temp-buffer
              (insert-file-contents abs)
              (buffer-string)))))
    (error (format "Error reading %s: %s" relpath (error-message-string err)))))

(defun coding-agent--tool-list-dir (relpath)
  "List RELPATH (default \".\") under the project root, one entry per line.
Hidden/internal files are excluded; directories end with /."
  (condition-case err
      (let* ((abs (coding-agent--tool-path (or relpath "."))))
        (mapconcat
         (lambda (name)
           (if (file-directory-p (expand-file-name name abs))
               (concat name "/")
             name))
         (cl-remove-if #'coding-agent--hidden-file-p
                       (directory-files abs nil "^[^.]" t))
         "\n"))
    (error (format "Error listing %s: %s" relpath (error-message-string err)))))

(defun coding-agent--tool-grep (pattern relpath)
  "Recursively grep for PATTERN (extended regex) under RELPATH."
  (condition-case err
      (let* ((abs (coding-agent--tool-path (or relpath ".")))
             (exe (if (executable-find "rg")
                      (list "rg" "--no-heading" "-n" "--color=never"
                            "--hidden" "--glob" "!.git/**" pattern abs)
                    (list "grep" "-rnE" pattern abs)))
             (out (with-temp-buffer
                    (apply #'process-file (car exe) nil t nil (cdr exe))
                    (buffer-string))))
        (coding-agent--truncate out 8000))
    (error (format "Error running grep: %s" (error-message-string err)))))

(defun coding-agent--tool-run-shell (command)
  "Run a whitelisted shell COMMAND with no shell (word-split argv); return output."
  (condition-case err
      (let ((tokens (split-string (string-trim command) "[ \t]+" t)))
        (cond
         ((null tokens) "Error: empty command")
         ((not (member (car tokens) coding-agent-shell-command-whitelist))
          (format "Error: command '%s' not whitelisted.  Allowed: %s"
                  (car tokens)
                  (mapconcat #'identity coding-agent-shell-command-whitelist ", ")))
         (t
          (let* ((root (or (plist-get coding-agent--agent-session :root)
                           default-directory))
                 (default-directory root)
                 (out (with-temp-buffer
                        (let ((code (apply #'process-file (car tokens) nil t nil
                                           (cdr tokens))))
                          (format "%s\n(exit %d)" (buffer-string) code)))))
            (coding-agent--truncate out 4000)))))
    (error (format "Error running command: %s" (error-message-string err)))))

(defun coding-agent--tool-propose-edit (relpath old new)
  "Propose replacing the contents of RELPATH: OLD must match, NEW is written.
Shows a unified diff; the change is applied on user approval (review supports
yes/no/skip), then `coding-agent-check-command' runs and its result is
returned.  Everything is returned as a string for the model."
  (condition-case err
      (let* ((abs   (coding-agent--tool-path relpath))
             (exists (file-exists-p abs))
             (current (and exists (coding-agent--file-contents abs))))
        (cond
         ((null new) "Error: \"new\" is required")
         ((null old) "Error: \"old\" is required (use the empty string for a new file)")
         ((and exists (not (string= current old)))
          (format "Error: stale base: on-disk contents of %s do not match the \"old\" you provided.  Read the file again and retry."
                  relpath))
         ((and exists (string= current new))
          "No changes (proposed content matches the current file)")
         ((and (not exists) (string-empty-p new))
          "Error: refused to create an empty file")
         (t
          (let ((diff-buf (coding-agent--diff-strings
                           (or current "") new "*coding-agent-diff*"))
                (buf (coding-agent--find-or-make-file-buffer abs)))
            (display-buffer diff-buf)
            (let ((outcome
                   (cond
                    (coding-agent-dry-run 'no)
                    (coding-agent-auto-approve 'apply)
                    (t (coding-agent--review-prompt
                        (format "Apply proposed changes to %s? " relpath))))))
              (pcase outcome
                ('apply
                 (if coding-agent-dry-run
                     "dry-run: diff shown, file not written"
                   (unless (file-directory-p (file-name-directory abs))
                     (make-directory (file-name-directory abs) t))
                   (with-temp-file abs (insert new))
                   (let ((after (and (buffer-live-p buf)
                                     (with-current-buffer buf
                                       (revert-buffer nil t t)))))
                     (ignore after))
                   (let ((status (coding-agent--run-check buf)))
                     (format "applied%s"
                             (if status (concat "; " status) "")))))
                (`(skip . ,reason)
                 (format "user skipped this change: %s" reason))
                (_ "user rejected the change")))))))
    (error (format "Error: propose_edit raised: %s" (error-message-string err)))))

;; -- Tool definitions ------------------------------------------------------

(defun coding-agent--agent-tools ()
  "Return the list of gptel tools available to the agentic session."
  (list
   (gptel-make-tool
    :name "read_file"
    :function #'coding-agent--tool-read-file
    :description "Read and return the contents of a file.  Refuses to read hidden/internal files (~, #...#, dotfiles) or secret-looking files (.env, *.pem, ...)."
    :args (list '(:name "path" :type string
                        :description "File path relative to the project root."))
    :category "coding-agent")
   (gptel-make-tool
    :name "list_dir"
    :function #'coding-agent--tool-list-dir
    :description "List files and subdirectories (with trailing /) of a directory.  Hidden/internal files are excluded."
    :args (list '(:name "path" :type string
                        :description "Directory path relative to the project root; use \".\" for the root.")
                )
    :category "coding-agent")
   (gptel-make-tool
    :name "grep"
    :function #'coding-agent--tool-grep
    :description "Recursively grep files for a pattern (extended regex; uses ripgrep when available)."
    :args (list '(:name "pattern" :type string
                        :description "Extended regex pattern to search for.")
                '(:name "path" :type string
                        :description "Directory or file path to search, relative to the project root."))
    :category "coding-agent")
   (gptel-make-tool
    :name "run_shell"
    :function #'coding-agent--tool-run-shell
    :description (format "Run a whitelisted shell command with no shell interpretation (the string is split on whitespace into an argv).  Whitelist: %s.  Returns combined stdout/stderr and the exit code."
                         (mapconcat #'identity coding-agent-shell-command-whitelist ", "))
    :args (list '(:name "command" :type string
                        :description "The command line, e.g. \"make check\"."))
    :category "coding-agent")
   (gptel-make-tool
    :name "propose_edit"
    :function #'coding-agent--tool-propose-edit
    :description "Propose an edit or a new-file creation.  For an existing file, \"old\" must equal the file's exact current contents (read it first with read_file); for a new file pass the empty string.  The user is shown a unified diff with yes/no/skip; on approval the file is written and the check command runs.  The result string says whether the edit was applied, rejected, or skipped (with the user's reason)."
    :args (list '(:name "path" :type string
                        :description "Path of the file to edit or create, relative to the project root.")
                '(:name "old" :type string
                        :description "Exact current contents of the file, or the empty string for a new file.")
                '(:name "new" :type string
                        :description "The proposed new contents of the file, in full."))
    :category "coding-agent")))

;; -- Agentic callback with repetition guard --------------------------------

(defconst coding-agent--agent-repeat-window 5
  "Number of recent tool-call batches remembered for loop detection.")

(defconst coding-agent--agent-repeat-limit 2
  "Identical tool-call batches seen within the window before halting.")

(defun coding-agent--call-signature (calls)
  "Return a sorted signature string list for gptel tool CALLS."
  (sort (mapcar (lambda (c)
                  (format "%s|%S" (gptel-tool-name (car c)) (cdr c)))
                calls)
        #'string<))

(defun coding-agent--agent-callback (response info)
  "Handle RESPONSE/INFO for the agentic session, looping on tool calls."
  (let* ((session coding-agent--agent-session)
         (src (plist-get session :buffer)))
    (cond
     ;; Terminal states ----------------------------------------------------
     ((null response)
      (setq coding-agent--agent-session nil)
      (coding-agent--set-busy (or src (current-buffer)) nil)
      (coding-agent--report-error info))
     ((eq response 'abort)
      (setq coding-agent--agent-session nil)
      (coding-agent--set-busy (or src (current-buffer)) nil)
      (message "coding-agent: agentic session aborted"))
     ((stringp response)                ; final assistant message, done
      (coding-agent--record-usage info)
      (coding-agent--history-push 'assistant response)
      (setq coding-agent--agent-session nil)
      (coding-agent--set-busy (or src (current-buffer)) nil)
      (message "coding-agent: agentic session complete; summary in *coding-agent-history*")
      (coding-agent-show-history))
     ;; Tool calls ----------------------------------------------------------
     ((and (consp response) (eq (car response) 'tool-result)) nil)
     ((and (consp response) (eq (car response) 'tool-call))
      (coding-agent--record-usage info)
      (let* ((calls (cdr response))
             (sig   (coding-agent--call-signature calls))
             (seen  (plist-get session :signatures))
             (n     (1+ (cl-count sig seen :test #'equal))))
        (if (>= n coding-agent--agent-repeat-limit)
            (progn
              (setq coding-agent--agent-session nil)
              (coding-agent--set-busy (or src (current-buffer)) nil)
              (message "coding-agent: stopped -- the model repeated the identical tool call(s) %d times; it may be stuck"
                       coding-agent--agent-repeat-limit))
          (setf (plist-get session :signatures)
                (last (cons sig seen) coding-agent--agent-repeat-window))
          ;; Run each tool and hand results back through gptel's callback.
          (dolist (call calls)
            (pcase-let ((`(,tool ,args ,cb) call))
              (coding-agent--history-push
               'note (format "tool call: %s %S" (gptel-tool-name tool) args))
              (let ((result
                     (condition-case err
                         (apply (gptel-tool-function tool)
                                (mapcar #'cdr args)) ; args are (NAME . VALUE)
                       (error
                        (format "Error: tool '%s' raised: %s"
                                (gptel-tool-name tool)
                                (error-message-string err))))))
                (coding-agent--history-push
                 'note (format "tool result: %s"
                               (coding-agent--truncate (format "%s" result) 500)))
                (funcall cb result)))))))
     (t nil))                           ; reasoning chunks: ignore
    ;; Iteration guard
    (when coding-agent--agent-session
      (let ((iters (cl-incf (plist-get coding-agent--agent-session :iterations))))
        (when (>= iters coding-agent-agent-max-iterations)
          (setq coding-agent--agent-session nil)
          (coding-agent--set-busy (or src (current-buffer)) nil)
          (message "coding-agent: stopped after %d iterations (max)"
                   coding-agent-agent-max-iterations))))))

(defun coding-agent-agent-run (instruction)
  "Run an agentic coding session: the model uses tools to satisfy INSTRUCTION.
Starts at the project root (directory containing .git, else
`default-directory') and lets the model call read_file, list_dir, grep,
run_shell and propose_edit.  With \\[universal-argument], first enrich with
web search results."
  (interactive "sAgentic instruction: ")
  (when coding-agent--agent-session
    (user-error "coding-agent: an agentic session is already running"))
  (coding-agent--ensure-not-busy)
  (coding-agent--ensure-key)
  (when (and current-prefix-arg
             (not (coding-agent-enrich-with-search)))
    (user-error "coding-agent: search enrichment failed"))
  (let* ((root (or (locate-dominating-file default-directory ".git")
                   (expand-file-name default-directory)))
         (fb   (coding-agent--consume-feedback))
         (instr (string-join
                 (delq nil (list instruction fb (coding-agent--search-results)))
                 "\n\n"))
         (system (concat (coding-agent--skill-preamble)
                         (coding-agent--agent-system-prompt)
                         (format "\n\nWorking directory: %s" root)))
         (gptel-tools (coding-agent--agent-tools))
         (gptel-use-tools t)
         (gptel-max-tokens 32768))
    (coding-agent--ensure-model-registered)
    (setq coding-agent--agent-session
          (list :buffer (current-buffer) :root root :iterations 0
                :signatures nil))
    (coding-agent--set-busy (current-buffer) t)
    (coding-agent--history-push 'user instr)
    (message "coding-agent: starting agentic session in %s (%s/%s)..."
             root (coding-agent--provider-label) coding-agent-model)
    (let ((gptel-backend coding-agent-backend)
          (gptel-model coding-agent-model))
      (gptel-request instr
        :stream nil
        :system system
        :callback #'coding-agent--agent-callback))))

(defun coding-agent-agent-stop ()
  "Abort a running agentic session."
  (interactive)
  (when coding-agent--agent-session
    (setq coding-agent--agent-session nil)
    (coding-agent--set-busy (current-buffer) nil)
    (message "coding-agent: agentic session stopped")))

;; ---------------------------------------------------------------------------
;; Conversation history, context display and compaction
;; ---------------------------------------------------------------------------

(defvar-local coding-agent--history nil
  "Chronological list of (ROLE . TEXT) entries for this buffer.
ROLE is one of `user', `assistant', `note' or `summary'.")

(defun coding-agent--history-push (role text)
  "Append (ROLE . TEXT) to the current buffer's history."
  (setq coding-agent--history
        (append coding-agent--history (list (cons role text)))))

(defun coding-agent-show-history ()
  "Show the conversation history for this buffer in a popup."
  (interactive)
  (let ((history coding-agent--history))
    (with-current-buffer (get-buffer-create "*coding-agent-history*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (null history)
            (insert "(no history for this buffer)\n")
          (dolist (entry history)
            (insert (propertize (format "\n--- %s ---\n" (car entry))
                                'face 'bold)
                    (or (cdr entry) "")
                    "\n"))))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer))
      (current-buffer))))

(defun coding-agent--wrap-text (text width)
  "Wrap TEXT at word boundaries to WIDTH columns.  Return a list of lines."
  (let ((words (split-string text " +" t))
        (lines '())
        (cur ""))
    (dolist (w words)
      (if (string-empty-p cur)
          (setq cur w)
        (let ((candidate (concat cur " " w)))
          (if (<= (length candidate) width)
              (setq cur candidate)
            (push cur lines)
            (setq cur w)))))
    (when (not (string-empty-p cur))
      (push cur lines))
    (nreverse lines)))

(defun coding-agent-show-context ()
  "Show a multiline summary of this buffer's context with estimated tokens."
  (interactive)
  (let ((entries coding-agent--history)
        (total 0)
        (width 88))
    (with-current-buffer (get-buffer-create "*coding-agent-context*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "  #  role        chars  preview\n")
        (insert "---  ---------  -------  " (make-string (min 40 width) ?-) "\n")
        (let ((i 0))
          (dolist (e entries)
            (cl-incf i)
            (let* ((content (cdr e))
                   (flat (replace-regexp-in-string "[\n\t]+" " " content))
                   (lines (or (coding-agent--wrap-text flat (- width 25)) '("")))
                   (indent (make-string 25 ? )))
              (cl-incf total (length content))
              (insert (format "%3d  %-9s %7d  %s\n"
                              i (symbol-name (car e)) (length content)
                              (pop lines)))
              (dolist (l lines)
                (insert indent l "\n")))))
        (goto-char (point-min)))
      (special-mode)
      (display-buffer (current-buffer))
      (message "coding-agent: %d entries, %d chars, ~%d tokens (est.)"
               (length entries) total (ceiling total 4))
      (current-buffer))))

(defconst coding-agent--compact-prompt
  "You are a context compactor for a coding assistant.  Summarize the
conversation transcript into a compact brief that will replace it.
Preserve: the user's goals and instructions, decisions made, files created
or modified (with paths), important code and tool-output details, and
outstanding tasks.  Write dense bullets, no preamble."
  "System prompt used by `coding-agent-compact-context'.")

(defun coding-agent--history-transcript ()
  "Render history as a single transcript string."
  (mapconcat (lambda (e) (format "### %s\n%s" (car e) (cdr e)))
             coding-agent--history "\n\n"))

(defun coding-agent-compact-context ()
  "Replace the buffer's history with an LLM-generated summary.
Asks the model to compact the transcript and folds the result back in as
a single `summary' entry."
  (interactive)
  (coding-agent--ensure-not-busy)
  (cond
   ((<= (length coding-agent--history) 1)
    (message "coding-agent: nothing to compact"))
   (t
    (let* ((src (current-buffer))
           (count (length coding-agent--history))
           (transcript (coding-agent--history-transcript)))
      (coding-agent--set-busy src t)
      (coding-agent--request
       (concat coding-agent--compact-prompt "\n\nTRANSCRIPT:\n" transcript)
       :stream nil
       :callback
       (lambda (response info)
         (when (buffer-live-p src)
           (with-current-buffer src
             (coding-agent--set-busy src nil)
             (coding-agent--record-usage info)
             (if (not (stringp response))
                 (coding-agent--report-error info)
               (setq coding-agent--history
                     (list (cons 'summary
                                 (concat "[Earlier conversation compacted. "
                                         "Continue from where it left off.]\n\n"
                                         response))))
               (message "coding-agent: compacted %d entries -> 1 (~%d chars)"
                        count (length response)))))))))))

(defun coding-agent-help ()
  "Show a short coding-agent cheatsheet."
  (interactive)
  (message
   (concat
    "coding-agent\n"
    "  C-c a r  run (file)      C-c a p  run (project)     C-c a R  agentic run\n"
    "  C-c a f  refine last     C-c a a  apply proposed\n"
    "  C-c a e  eval/check      C-c a .  menu   C-c a h  help\n"
    "  C-c a m  change model/provider   C-c a g  reset busy flag\n"
    "  C-c a H  history  C-c a T context  C-c a C compact  C-c a u tokens\n"
    "  C-c a /  load skill   C-c a s search+enrich  C-c a S search on/off\n"
    "  C-c l r  send region     C-c l c  chat buffer\n"
    "Reviews: y = apply, n = reject, s = skip with a reason sent to the model.\n"
    "Prefix arg on run/refine/project/agent enriches the prompt with web search.")))

(transient-define-prefix coding-agent-dispatch ()
  "Coding-agent command menu."
  [["Edit"
    ("r" "Run on file"      coding-agent-run)
    ("p" "Run on project"   coding-agent-run-project)
    ("R" "Agentic run"      coding-agent-agent-run)
    ("f" "Refine last"      coding-agent-refine)
    ("a" "Apply proposed"   coding-agent-apply-proposed)]
   ["Session"
    ("H" "History"          coding-agent-show-history)
    ("T" "Context summary"  coding-agent-show-context)
    ("C" "Compact context"  coding-agent-compact-context)
    ("u" "Token usage"      coding-agent-session-usage)
    ("g" "Reset busy flag"  coding-agent-reset)
    ("X" "Stop agent"       coding-agent-agent-stop)]
   ["Context"
    ("/" "Load skill"       coding-agent-load-skill)
    ("?" "Clear skills"     coding-agent-clear-skills)
    ("s" "Web search"       coding-agent-enrich-with-search)
    ("S" "Toggle search"    coding-agent-toggle-search)]
   ["Other"
    ("e" "Eval / check buffer"    coding-agent-eval-buffer-for-language)
    ("m" "Model / provider"       coding-agent-model-change)
    ("c" "Chat: region/buffer"    coding-agent-send-region-or-buffer)
    ("h" "Help"                   coding-agent-help)]])

;; ---------------------------------------------------------------------------
;; Keymap and minor mode (no global bindings until the mode is enabled)
;; ---------------------------------------------------------------------------

(defvar coding-agent-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'coding-agent-run)
    (define-key map (kbd "p") #'coding-agent-run-project)
    (define-key map (kbd "R") #'coding-agent-agent-run)
    (define-key map (kbd "X") #'coding-agent-agent-stop)
    (define-key map (kbd "f") #'coding-agent-refine)
    (define-key map (kbd "a") #'coding-agent-apply-proposed)
    (define-key map (kbd "e") #'coding-agent-eval-buffer-for-language)
    (define-key map (kbd "m") #'coding-agent-model-change)
    (define-key map (kbd "g") #'coding-agent-reset)
    (define-key map (kbd "h") #'coding-agent-help)
    (define-key map (kbd "H") #'coding-agent-show-history)
    (define-key map (kbd "T") #'coding-agent-show-context)
    (define-key map (kbd "C") #'coding-agent-compact-context)
    (define-key map (kbd "u") #'coding-agent-session-usage)
    (define-key map (kbd "/") #'coding-agent-load-skill)
    (define-key map (kbd "s") #'coding-agent-enrich-with-search)
    (define-key map (kbd "S") #'coding-agent-toggle-search)
    (define-key map (kbd "D") #'coding-agent-toggle-dry-run)
    (define-key map (kbd "A") #'coding-agent-toggle-auto-approve)
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

;; Load JSON profile providers once at startup (no-op when the config files
;; are absent); must come after the provider variables above.
(coding-agent-load-harness-config)

(provide 'coding-agent)
;;; coding-agent.el ends here
