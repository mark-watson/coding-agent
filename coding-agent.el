;;; -*- lexical-binding: t; -*-
;;; coding-agent.el --- LLM-powered coding agent using gptel

;; ---------------------------------------------------------------------------
;; USAGE
;; ---------------------------------------------------------------------------
;;
;; 1. SEND A CODING INSTRUCTION TO THE LLM (single file)
;;      M-x ca-run-agent   (or  C-c a r)
;;      You will be prompted for an instruction, e.g.:
;;        "add comments"
;;        "refactor to use let* instead of let"
;;        "add type hints to all function arguments"
;;      The current buffer's source code is sent to the LLM together with
;;      your instruction.
;;
;; 1b. SEND A CODING INSTRUCTION TO THE LLM (multi-file project)
;;      M-x ca-run-agent-project   (or  C-c a p)
;;      Collects all source files in the current directory and subdirectories
;;      (filtered to the current language's extensions) using `rg --files'
;;      or `find' as a fallback.  All files are bundled into one prompt.
;;      The LLM response must use FILE: <path> / END_FILE delimiters so
;;      each modified file can be extracted and reviewed individually.
;;
;; 2. REVIEW THE PROPOSED CHANGES
;;      When the LLM responds, two things happen automatically:
;;        *agent-proposed*  — a new buffer containing the full rewritten code
;;        *agent-diff*      — a unified diff of original vs proposed
;;      An ediff session is also launched for side-by-side comparison.
;;      For multi-file responses each modified file gets its own ediff session
;;      (in sequence); you can accept or reject each one independently.
;;
;; 3. ACCEPT THE CHANGES
;;      Option A (quick):
;;        M-x ca-apply-proposed
;;        Writes the proposed code into the source buffer and saves the file.
;;      Option B (via ediff):
;;        Navigate diffs with  n / p,  then press  q  to quit ediff.
;;        Answer  y  to the "Apply proposed changes?" prompt.
;;
;; 4. EVALUATE / SYNTAX-CHECK THE BUFFER (optional)
;;      M-x ca-eval-buffer-for-language   (or  C-c a e)
;;      Runs the appropriate checker for the buffer's language:
;;        Python       → python-shell-send-buffer
;;        Common Lisp  → slime-compile-and-load-file
;;        Clojure      → cider-load-buffer
;;
;; KEYBINDINGS SUMMARY
;;   C-c a r  →  ca-run-agent              (send instruction to LLM, single file)
;;   C-c a p  →  ca-run-agent-project      (send instruction to LLM, whole project)
;;   C-c a e  →  ca-eval-buffer-for-language
;;   C-c a h  →  ca-help
;;   C-c l r  →  my-llm-send-region-or-buffer  (raw gptel chat)
;;   C-c l c  →  gptel-chat
;;
;; ---------------------------------------------------------------------------

;; ---------------------------------------------------------------------------
;; Global state
;; ---------------------------------------------------------------------------

(defvar ca-source-buffer nil
  "The buffer that was active when `ca-run-agent' was last called.")

(defvar ca-diff-buffer-name "*agent-diff*"
  "Name of the unified-diff review buffer.")

(defvar ca--proposed-text nil
  "Proposed replacement text produced by the last LLM response.")

;; Forward declarations to satisfy the byte-compiler and flycheck.
(declare-function ca-detect-language           "coding-agent")
(declare-function ca-build-prompt              "coding-agent")
(declare-function ca--strip-fences             "coding-agent")
(declare-function ca--handle-response          "coding-agent")
(declare-function ca-open-diff-buffer          "coding-agent")
(declare-function ca-ediff-review              "coding-agent")
(declare-function ca-apply-proposed            "coding-agent")
(declare-function ca-collect-project-files     "coding-agent")
(declare-function ca-build-project-prompt      "coding-agent")
(declare-function ca--parse-multi-file-response "coding-agent")
(declare-function ca--handle-project-response  "coding-agent")
(declare-function ca-run-agent-project         "coding-agent")

;; ---------------------------------------------------------------------------
;; gptel package setup
;; ---------------------------------------------------------------------------

(use-package gptel
  :straight t
  :commands (gptel gptel-chat gptel-request)
  :config
  (defvar my-ollama-backend
    (gptel-make-ollama "Ollama"
      :host "localhost:11434"
      :models '(glm-5:cloud)
      :stream t))

  (setq gptel-backend my-ollama-backend
        gptel-model  'glm-5:cloud)

  (defun my-llm-send-region-or-buffer ()
    (interactive)
    (let ((prompt
           (if (use-region-p)
               (buffer-substring (region-beginning) (region-end))
             (buffer-substring-no-properties (point-min) (point-max)))))
      (gptel-chat prompt)))
  (global-set-key (kbd "C-c l r") #'my-llm-send-region-or-buffer)
  (global-set-key (kbd "C-c l c") #'gptel-chat))

;; ---------------------------------------------------------------------------
;; Language detection
;; ---------------------------------------------------------------------------

(defun ca-detect-language (buf)
  "Return a language string for BUF based on its major mode."
  (with-current-buffer buf
    (pcase major-mode
      ('python-mode       "python")
      ('lisp-mode         "common-lisp")
      ('clojure-mode      "clojure")
      ('js-mode           "javascript")
      ('js2-mode          "javascript")
      ('typescript-mode   "typescript")
      ('ruby-mode         "ruby")
      ('go-mode           "go")
      ('rust-mode         "rust")
      ('c-mode            "c")
      ('c++-mode          "c++")
      ('java-mode         "java")
      ('emacs-lisp-mode   "emacs-lisp")
      ('sh-mode           "shell")
      (_                  "text"))))


(defun ca-build-prompt (language source instruction)
  "Build the LLM prompt for LANGUAGE with SOURCE and INSTRUCTION."
  (format "You are an expert %s programmer.
Return ONLY the complete modified source file, with no explanation,
no markdown code fences, no preamble, no commentary.
Do not write ``` or ```%s. Output raw source code only.

INSTRUCTION: %s

SOURCE:
%s" language language instruction source))


(defun ca-run-agent (instruction)
  "Send INSTRUCTION about the current source buffer to the LLM.
Refuses to operate on binary files (those whose extension is not in
`ca--text-extensions')."
  (interactive "sInstruction: ")
  (let ((file (buffer-file-name)))
    (when (and file (not (ca--text-file-p file)))
      (user-error "coding-agent: '%s' looks like a binary file; skipping"
                  (file-name-nondirectory file))))
  (setq ca-source-buffer (current-buffer))
  (let* ((lang    (ca-detect-language ca-source-buffer))
         (source  (buffer-string))
         (prompt  (ca-build-prompt lang source instruction)))
    (gptel-request prompt
      :callback #'ca--handle-response
      :stream   nil)))


(defun ca--strip-fences (text)
  "Remove markdown code fences from TEXT if present."
  (let ((s (string-trim text)))
    ;; Strip opening fence: ```<lang>\n
    (when (string-match "\\`[ \t]*```[a-zA-Z]*\n?" s)
      (setq s (substring s (match-end 0))))
    ;; Strip closing fence: ```
    (when (string-match "\n?[ \t]*```[ \t]*\\'" s)
      (setq s (substring s 0 (match-beginning 0))))
    s))

(defun ca--handle-response (response info)
  "gptel callback: handle RESPONSE from the LLM or an error INFO plist.
Thinking/reasoning models call this once per content block; non-string
blocks (e.g. reasoning cons cells) are silently skipped."
  (cond
   ((not response)
    (message "Agent error: %s" info))
   ((not (stringp response))
    ;; Reasoning / thinking block — not the code output; ignore it.
    nil)
   (t
    (let* ((original (with-current-buffer ca-source-buffer (buffer-string)))
           (proposed (ca--strip-fences response)))
      (setq ca--proposed-text proposed)
      (ca-ediff-review original proposed)
      (message "Review diff in *agent-diff* / ediff.  M-x ca-apply-proposed to accept.")))))


(defun ca-open-diff-buffer (original proposed language)
  "Open a unified diff buffer comparing ORIGINAL and PROPOSED strings for LANGUAGE."
  (let* ((orig-file (make-temp-file "ca-orig-"))
         (prop-file (make-temp-file "ca-prop-"))
         (diff-buf  (get-buffer-create ca-diff-buffer-name))
         (orig-buf  (get-buffer-create "*agent-orig*"))
         (prop-buf  (get-buffer-create "*agent-proposed*"))
         (mode-fn   (pcase language
                      ("python"       #'python-mode)
                      ("common-lisp"  #'lisp-mode)
                      ("clojure"      #'clojure-mode)
                      (_              #'fundamental-mode))))
    (write-region original nil orig-file nil 'silent)
    (write-region proposed nil prop-file nil 'silent)
    (with-current-buffer orig-buf
      (erase-buffer) (insert original) (funcall mode-fn))
    (with-current-buffer prop-buf
      (erase-buffer) (insert proposed) (funcall mode-fn))
    (with-current-buffer diff-buf
      (erase-buffer)
      (call-process "diff" nil diff-buf nil "-u" orig-file prop-file)
      (diff-mode)
      (goto-char (point-min)))
    (delete-file orig-file)
    (delete-file prop-file)
    (display-buffer diff-buf)
    (list orig-buf prop-buf)))


(defun ca--ediff-quit-hook ()
  "Hook run when the coding-agent ediff session quits."
  (remove-hook 'ediff-quit-hook #'ca--ediff-quit-hook)
  (when (y-or-n-p "Apply proposed changes to source buffer? ")
    (ca-apply-proposed ca--proposed-text)))

(defun ca-ediff-review (original proposed)
  "Launch an ediff session comparing ORIGINAL and PROPOSED text.
 Also opens a *agent-proposed* buffer so the new code is visible."
  (let* ((lang      (ca-detect-language ca-source-buffer))
         (bufs      (ca-open-diff-buffer original proposed lang))
         (orig-buf  (car bufs))
         (prop-buf  (cadr bufs)))
    ;; Show the proposed code in its own window before launching ediff.
    (display-buffer prop-buf
                    '((display-buffer-pop-up-window)
                      (inhibit-same-window . t)))
    (add-hook 'ediff-quit-hook #'ca--ediff-quit-hook)
    (ediff-buffers orig-buf prop-buf)))


;; ---------------------------------------------------------------------------
;; Apply proposed changes
;; ---------------------------------------------------------------------------

(defun ca-apply-proposed (&optional proposed-text)
  "Replace the contents of `ca-source-buffer' with PROPOSED-TEXT and save.
When called interactively (M-x ca-apply-proposed) uses `ca--proposed-text'."
  (interactive)
  (let ((text (or proposed-text ca--proposed-text)))
    (if (not text)
        (message "coding-agent: no proposed text to apply")
      (when (buffer-live-p ca-source-buffer)
        (with-current-buffer ca-source-buffer
          (erase-buffer)
          (insert text)
          (save-buffer)
          (message "coding-agent: changes applied to %s"
                   (buffer-name ca-source-buffer)))))))


;; ---------------------------------------------------------------------------
;; Multi-file project support
;; ---------------------------------------------------------------------------

(defvar ca-project-root nil
  "Root directory used by the last `ca-run-agent-project' call.")

(defvar ca--project-file-table nil
  "Hash-table mapping relative file path → original content for the project run.")

(defconst ca--language-extensions
  '(("python"       . ("py"))
    ("common-lisp"  . ("lisp" "cl" "asd"))
    ("clojure"      . ("clj" "cljs" "cljc" "edn"))
    ("javascript"   . ("js" "mjs" "cjs"))
    ("typescript"   . ("ts" "tsx"))
    ("ruby"         . ("rb"))
    ("go"           . ("go"))
    ("rust"         . ("rs"))
    ("c"            . ("c" "h"))
    ("c++"          . ("cpp" "cc" "cxx" "hpp" "hh"))
    ("java"         . ("java"))
    ("emacs-lisp"   . ("el"))
    ("markdown"     . ("md"))
    ("hy"           . ("hy"))
    ("shell"        . ("sh" "bash" "zsh")))
  "Alist mapping ca language strings to lists of file extensions.")

(defconst ca--text-extensions
  '("asd" "bash" "c" "cc" "cfg" "cl" "clj" "cljc" "cljs" "cmake"
    "conf" "cpp" "css" "csv" "cxx" "edn" "el" "env" "ex" "exs"
    "go" "gradle" "graphql" "h" "hh" "hpp" "hs" "html" "ini"
    "java" "js" "json" "jsx" "kt" "lisp" "lua" "makefile" "md"
    "mjs" "ml" "mli" "org" "php" "pl" "pm" "properties" "proto"
    "py" "r" "rb" "rs" "rst" "scala" "sh" "sql" "swift" "tex"
    "toml" "ts" "tsx" "txt" "vb" "vue" "xml" "yaml" "yml" "zsh")
  "Whitelist of file extensions treated as plain text by coding-agent.
Files whose extension is NOT in this list are considered binary and skipped.")

(defun ca--text-file-p (filename)
  "Return non-nil when FILENAME has an extension in `ca--text-extensions'.
Files with no extension are also treated as text (e.g. Makefile, Dockerfile)."
  (let ((ext (file-name-extension filename)))
    (or (null ext)
        (member (downcase ext) ca--text-extensions))))

(defun ca--extensions-for-language (lang)
  "Return the list of file extensions appropriate for LANG."
  (cdr (assoc lang ca--language-extensions)))

(defun ca-collect-project-files (root lang)
  "Return a list of source files under ROOT matching LANG's extensions.
Uses `rg --files' when available, falling back to `find'.
Files under hidden directories (.*) and common build/dependency dirs
\(node_modules, target, .git, __pycache__, etc.) are excluded.
Returns absolute paths, sorted."
  (let* ((exts      (ca--extensions-for-language lang))
         (ignore-dirs '(".git" ".hg" ".svn" "node_modules" "target"
                        ".cpcache" ".clj-kondo" ".lsp" "__pycache__"
                        ".mypy_cache" ".tox" "dist" "build" ".build"
                        ".stack-work" "vendor" "_build" ".gradle"))
         files)
    (if (null exts)
        ;; Unknown language: return just the files with any extension
        (setq files
              (split-string
               (shell-command-to-string
                (concat "find " (shell-quote-argument root)
                        " -type f -not -path '*/.*' 2>/dev/null"))
               "\n" t))
      (if (executable-find "rg")
          ;; Fast path: ripgrep
          (let* ((glob-args (mapconcat (lambda (e)
                                         (concat "-g '*." e "'"))
                                       exts " "))
                 (ignore-args (mapconcat (lambda (d)
                                           (concat "--ignore-file /dev/null "
                                                   "-g '!" d "/**'"))
                                         ignore-dirs " "))
                 (cmd (format "rg --files %s %s %s 2>/dev/null"
                              glob-args ignore-args
                              (shell-quote-argument root))))
            (setq files (split-string (shell-command-to-string cmd) "\n" t)))
        ;; Slow path: find
        (let* ((name-clauses
                (mapconcat (lambda (e) (format "-name '*.%s'" e))
                            exts " -o "))
               (prune-exprs
                (mapconcat (lambda (d)
                              (format "-path '*/%s' -prune" d))
                            ignore-dirs " -o "))
               (cmd (format "find %s \\( %s \\) -o \\( \\( %s \\) -print \\) 2>/dev/null"
                            (shell-quote-argument root)
                            prune-exprs
                            name-clauses)))
          (setq files (split-string (shell-command-to-string cmd) "\n" t)))))
    (sort (cl-remove-if-not
           (lambda (f) (and (file-regular-p f) (ca--text-file-p f)))
           files)
          #'string<)))

(defun ca-build-project-prompt (language files-alist instruction)
  "Build a multi-file LLM prompt for LANGUAGE.
FILES-ALIST is a list of (relative-path . content) pairs.
INSTRUCTION is the user's coding request.

The LLM is asked to return ONLY the files it modified, each wrapped
in FILE: <path> … END_FILE delimiters."
  (let ((files-block
         (mapconcat (lambda (pair)
                      (format "FILE: %s\n%s\nEND_FILE" (car pair) (cdr pair)))
                    files-alist "\n\n")))
    (format
     "You are an expert %s programmer working on a multi-file project.

INSTRUCTION: %s

Below are ALL the source files in the project, each wrapped in
  FILE: <relative-path>\n<content>\nEND_FILE
delimiters.

Return ONLY the files that you modified, using the SAME delimiter format:
  FILE: <relative-path>\n<new content>\nEND_FILE

Do NOT include files that are unchanged.
Do NOT output any explanation, markdown, or code fences.
Output raw source code only inside the delimiters.

PROJECT FILES:
%s"
     language instruction files-block)))

(defun ca--parse-multi-file-response (response)
  "Parse RESPONSE from `ca-run-agent-project' into an alist of (path . content).
Expects the format  FILE: <path>\n<content>\nEND_FILE per modified file."
  (let ((result '())
        (start 0))
    (while (string-match "FILE: \\([^\n]+\\)\n" response start)
      (let* ((path    (string-trim (match-string 1 response)))
             (content-start (match-end 0))
             (end-marker    (string-match "\nEND_FILE" response content-start)))
        (if (null end-marker)
            ;; Malformed: take the rest of the string as content
            (push (cons path (substring response content-start)) result)
          (push (cons path (substring response content-start end-marker)) result)
          (setq start (+ end-marker (length "\nEND_FILE"))))))
    (nreverse result)))

(defvar ca--project-pending-files nil
  "Queue of (path . proposed-content) pairs waiting for ediff review.")

(defun ca--project-next-review ()
  "Pop the next file from `ca--project-pending-files' and launch ediff for it.
Installs itself as an `ediff-quit-hook' so reviews proceed in sequence."
  (if (null ca--project-pending-files)
      (message "coding-agent: all project files reviewed.")
    (let* ((pair       (pop ca--project-pending-files))
           (rel-path   (car pair))
           (proposed   (cdr pair))
           (abs-path   (expand-file-name rel-path ca-project-root))
           (original   (if (file-exists-p abs-path)
                           (with-temp-buffer
                             (insert-file-contents abs-path)
                             (buffer-string))
                         "")))
      (message "coding-agent: reviewing %s" rel-path)
      ;; Store per-file state for the quit hook.
      (setq ca-source-buffer
            (or (find-buffer-visiting abs-path)
                (let ((b (create-file-buffer abs-path)))
                  (with-current-buffer b
                    (insert original)
                    (set-visited-file-name abs-path t))
                  b)))
      (setq ca--proposed-text proposed)
      ;; Use the same single-file ediff machinery.
      (ca-ediff-review original proposed))))

(defun ca--handle-project-response (response info)
  "gptel callback for `ca-run-agent-project'."
  (cond
   ((not response)
    (message "Agent error: %s" info))
   ((not (stringp response))
    nil)  ; reasoning block, skip
   (t
    (let ((pairs (ca--parse-multi-file-response response)))
      (if (null pairs)
          (message "coding-agent: LLM returned no FILE: blocks. Raw response in *agent-project-raw*.")
        (message "coding-agent: %d file(s) modified by LLM. Starting review…" (length pairs))
        (setq ca--project-pending-files pairs)
        ;; Override the single-file ediff quit hook so it chains to the next file.
        (remove-hook 'ediff-quit-hook #'ca--ediff-quit-hook)
        (add-hook 'ediff-quit-hook #'ca--project-ediff-quit-hook)
        (ca--project-next-review))
      ;; Always save raw response for inspection.
      (with-current-buffer (get-buffer-create "*agent-project-raw*")
        (erase-buffer)
        (insert response)
        (goto-char (point-min)))))))

(defun ca--project-ediff-quit-hook ()
  "Hook run when a project-review ediff session quits."
  (remove-hook 'ediff-quit-hook #'ca--project-ediff-quit-hook)
  (when (y-or-n-p (format "Apply proposed changes to %s? "
                          (buffer-name ca-source-buffer)))
    (ca-apply-proposed ca--proposed-text))
  ;; Chain to the next file, re-installing the hook for it.
  (when ca--project-pending-files
    (add-hook 'ediff-quit-hook #'ca--project-ediff-quit-hook)
    (ca--project-next-review)))

(defun ca-run-agent-project (instruction)
  "Send INSTRUCTION about the WHOLE PROJECT to the LLM.
Collects source files under `default-directory' matching the current
buffer's language extensions (using `rg --files' or `find').
The LLM receives all files and returns only those it modifies,
using FILE: <path> / END_FILE delimiters.  Each modified file
is shown in a separate ediff review session in sequence."
  (interactive "sProject instruction: ")
  (let* ((root   (expand-file-name default-directory))
         (lang   (ca-detect-language (current-buffer)))
         (files  (ca-collect-project-files root lang)))
    (when (null files)
      (user-error "No source files found for language '%s' under %s" lang root))
    (message "coding-agent: collecting %d %s file(s) from %s…"
             (length files) lang root)
    (setq ca-project-root root)
    ;; Build alist of (relative-path . content)
    (let* ((files-alist
            (mapcar (lambda (abs)
                      (cons (file-relative-name abs root)
                            (with-temp-buffer
                              (insert-file-contents abs)
                              (buffer-string))))
                    files))
           (prompt (ca-build-project-prompt lang files-alist instruction)))
      ;; Cache originals for potential re-use
      (setq ca--project-file-table (make-hash-table :test #'equal))
      (dolist (pair files-alist)
        (puthash (car pair) (cdr pair) ca--project-file-table))
      (message "coding-agent: sending %d file(s) to LLM…" (length files))
      (gptel-request prompt
        :callback #'ca--handle-project-response
        :stream   nil))))


;; ---------------------------------------------------------------------------
;; Evaluate / syntax-check the current buffer
;; ---------------------------------------------------------------------------

(defun ca-eval-buffer-for-language ()
  "Run appropriate eval/check for current buffer's language."
  (interactive)
  (let ((lang (ca-detect-language (current-buffer))))
    (pcase lang
      ("python"      (python-shell-send-buffer))
      ("common-lisp" (slime-compile-and-load-file))
      ("clojure"     (cider-load-buffer))
      (_             (message "No eval command defined for language: %s" lang)))))


;; ---------------------------------------------------------------------------
;; Help / usage summary
;; ---------------------------------------------------------------------------

(defun ca-help ()
  "Print a short coding-agent usage cheatsheet to *Messages*."
  (interactive)
  (message
   (concat
    "coding-agent commands\n"
    "  C-c a r  ca-run-agent          — send instruction to LLM (single file)\n"
    "  C-c a p  ca-run-agent-project  — send instruction to LLM (whole project)\n"
    "  C-c a e  ca-eval-buffer        — eval/syntax-check buffer\n"
    "  C-c a h  ca-help               — this message\n"
    "  C-c l r  llm-send-region/buf   — raw gptel chat\n"
    "  C-c l c  gptel-chat            — open gptel chat buffer\n"
    "Single-file: ca-run-agent → ediff review → ca-apply-proposed\n"
    "Multi-file:  ca-run-agent-project → ediff per file → accept/reject each")))

;; ---------------------------------------------------------------------------
;; Keybindings for the agent
;; ---------------------------------------------------------------------------

(global-set-key (kbd "C-c a r") #'ca-run-agent)
(global-set-key (kbd "C-c a p") #'ca-run-agent-project)
(global-set-key (kbd "C-c a e") #'ca-eval-buffer-for-language)
(global-set-key (kbd "C-c a h") #'ca-help)

(provide 'coding-agent)
;;; coding-agent.el ends here
