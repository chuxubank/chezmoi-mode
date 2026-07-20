;;; chezmoi-test.el --- Tests for chezmoi -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi)

(defconst chezmoi-test--loaded-go-template-ts-mode-p
  (featurep 'go-template-ts-mode))

(require 'go-template-ts-mode nil t)

(ert-deftest chezmoi-does-not-load-poly-any-go-template ()
  (should-not (featurep 'poly-any-go-template)))

(ert-deftest chezmoi-does-not-load-go-template-ts-mode ()
  (should-not chezmoi-test--loaded-go-template-ts-mode-p))

(ert-deftest chezmoi-find-scripts-is-command ()
  (should (commandp #'chezmoi-find-scripts)))

(ert-deftest chezmoi-find-scripts-enables-chezmoi-template-support ()
  (let ((script (make-temp-file "run_once_setup.sh" nil ".tmpl"
                                "#!/bin/sh\n{{ .chezmoi.os }}\n"))
        (chezmoi-template-mode-hook nil)
        activated
        buffer)
    (unwind-protect
        (progn
          (add-hook 'chezmoi-template-mode-hook
                    (lambda () (setq activated t)))
          (setq buffer (chezmoi-find-scripts script))
          (with-current-buffer buffer
            (should chezmoi-mode)
            (should activated)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file script))))

(ert-deftest chezmoi-find-infers-mode-from-target-filename ()
  (let ((source (make-temp-file "dot_custom" nil nil
                                "(message \"managed\")\n"))
        (target "/tmp/custom.el")
        buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'chezmoi-source-file)
                   (lambda (_) source)))
          (chezmoi-find target)
          (setq buffer (current-buffer))
          (should (eq major-mode 'emacs-lisp-mode))
          (should chezmoi-mode))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file source))))

(ert-deftest chezmoi-dispatch-passes-arguments-without-shell-quoting ()
  (let ((chezmoi-command "printf"))
    (should (equal (chezmoi--dispatch '("%s" "hello world"))
                   '("hello world")))))

(ert-deftest chezmoi-managed-requests-abbreviated-absolute-paths ()
  (let ((absolute-file (expand-file-name "managed-file" "~/"))
        dispatched-args)
    (cl-letf (((symbol-function 'chezmoi--dispatch)
               (lambda (args)
                 (setq dispatched-args args)
                 (list absolute-file))))
      (should (equal (chezmoi-managed)
                     (list (abbreviate-file-name absolute-file))))
      (should (equal dispatched-args
                     '("managed" "-x" "externals,scripts"
                       "-p" "absolute"))))))

(ert-deftest chezmoi-transient-is-command ()
  (should (commandp #'chezmoi-transient)))

(ert-deftest chezmoi-transient-exposes-core-workflows ()
  (dolist (key '("f" "F" "o" "r"
                 "-f" "w" "s" "d" "S"
                 "m" "M" "q"
                 "D" "C" "x" "v" "t" "c"))
    (should (transient-get-suffix 'chezmoi-transient key))))

(ert-deftest chezmoi-transient-version-suffix-is-a-command ()
  (should (commandp #'chezmoi-version)))

(ert-deftest chezmoi-transient-write-passes-force-argument ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/dot_config")
    (let (write-args)
      (cl-letf (((symbol-function 'transient-args)
                 (lambda (_) '("--force")))
                ((symbol-function 'chezmoi-write)
                 (lambda (&rest args) (setq write-args args))))
        (call-interactively #'chezmoi-transient-write))
      (should (equal write-args
                     '("/tmp/chezmoi/dot_config" ("--force")))))))

(ert-deftest chezmoi-transient-sync-passes-force-prefix ()
  (let (received-prefix)
    (cl-letf (((symbol-function 'transient-args)
               (lambda (_) '("--force")))
              ((symbol-function 'chezmoi-sync-files)
               (lambda ()
                 (interactive)
                 (setq received-prefix current-prefix-arg))))
      (call-interactively #'chezmoi-transient-sync-files))
    (should (equal received-prefix '(4)))))

(ert-deftest chezmoi-transient-descriptions-reflect-buffer-state ()
  (let ((chezmoi-mode nil))
    (should (equal (chezmoi-transient--mode-description)
                   "Enable Chezmoi mode"))
    (setq chezmoi-mode t)
    (should (equal (chezmoi-transient--mode-description)
                   "Disable Chezmoi mode")))
  (with-temp-buffer
    (should (equal (chezmoi-transient--display-description)
                   "Display template values"))
    (setq chezmoi-template--buffer-displayed-p t)
    (should (equal (chezmoi-transient--display-description)
                   "Hide template values"))))

(ert-deftest chezmoi-display-command-output-preserves-argument-boundaries ()
  (let ((buffer-name "*chezmoi-test-output*")
        process-args
        displayed)
    (unwind-protect
        (cl-letf (((symbol-function 'call-process)
                   (lambda (_program _in destination _display &rest args)
                     (setq process-args args)
                     (with-current-buffer destination
                       (insert "{}"))
                     0))
                  ((symbol-function 'display-buffer)
                   (lambda (buffer &rest _)
                     (setq displayed buffer))))
          (let ((buffer (chezmoi--display-command-output
                         buffer-name '("dump-config") t)))
            (should (eq buffer displayed))
            (should (equal process-args '("dump-config")))
            (with-current-buffer buffer
              (should buffer-read-only))))
      (when-let ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest chezmoi-mode-initializes-template-module ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh.tmpl")
    (let ((activated nil)
          (changed-calls 0))
      (add-hook 'chezmoi-template-mode-hook
                (lambda () (setq activated t)) nil t)
      (cl-letf (((symbol-function 'chezmoi-changed-p)
                 (lambda (&rest _) (cl-incf changed-calls) nil))
                ((symbol-function 'chezmoi-template-buffer-display)
                 (lambda (&rest _) nil)))
        (chezmoi-mode 1)
        (should (= changed-calls 0))
        (should (memq #'chezmoi--write-after-save after-save-hook))
        (should (memq #'chezmoi-capf completion-at-point-functions))
        (chezmoi-mode -1)
        (should-not (memq #'chezmoi--write-after-save after-save-hook))
        (should-not (memq #'chezmoi-capf completion-at-point-functions)))
      (should activated))))

(ert-deftest chezmoi-mode-has-lighter ()
  (should (equal (cdr (assq 'chezmoi-mode minor-mode-alist))
                 '(" Chezmoi"))))

(ert-deftest chezmoi-template-display-is-enabled-by-default ()
  (should (default-value 'chezmoi-template-display-p)))

(ert-deftest chezmoi-mode-registers-capf-after-major-mode-change ()
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/modify_dot_config")
    (let ((chezmoi-root "/tmp/chezmoi/"))
      (add-hook 'chezmoi-template-mode-hook #'go-template-ts-mode nil t)
      (cl-letf (((symbol-function 'chezmoi-changed-p) (lambda (&rest _) nil)))
        (chezmoi-mode 1))
      (should chezmoi-mode)
      (should (eq major-mode 'go-template-ts-mode))
      (should (memq #'chezmoi-capf completion-at-point-functions)))))

(ert-deftest chezmoi-template-file-p-recognizes-template-sources ()
  (let ((chezmoi-root "/tmp/chezmoi/"))
    (should (chezmoi-template-file-p "/tmp/chezmoi/run.sh.tmpl"))
    (should (chezmoi-template-file-p "/tmp/chezmoi/modify_dot_config"))
    (should (chezmoi-template-file-p
             "/tmp/chezmoi/.chezmoitemplates/Brewfile"))
    (should (chezmoi-template-file-p
             "/tmp/chezmoi/.chezmoitemplates/script.sh"))
    (should-not (chezmoi-template-file-p
                 "/tmp/chezmoi/.chezmoitemplates-old/Brewfile"))
    (should-not (chezmoi-template-file-p "/tmp/chezmoi/run.sh.tmpl.bak"))))

(ert-deftest chezmoi-normalizes-template-host-filename ()
  (let ((chezmoi-root "/tmp/chezmoi/"))
    (should (equal
             (chezmoi-template-normalize-host-filename
              "/tmp/chezmoi/dot_zprofile")
             "/tmp/chezmoi/.zprofile"))))

(ert-deftest chezmoi-template-mode-hook-runs-only-for-template-sources ()
  (dolist (case '(("/tmp/chezmoi/modify_dot_config" . t)
                  ("/tmp/chezmoi/config.tmpl" . t)
                  ("/tmp/chezmoi/config.sh" . nil)))
    (with-temp-buffer
      (setq buffer-file-name (car case))
      (let ((called nil))
        (add-hook 'chezmoi-template-mode-hook
                  (lambda () (setq called t)) nil t)
        (cl-letf (((symbol-function 'chezmoi-template-schedule-buffer-display)
                   #'ignore))
          (chezmoi-mode 1))
        (should (eq called (cdr case)))))))

(ert-deftest chezmoi-source-file-p-treats-root-as-a-path ()
  (let* ((root (make-temp-file "chezmoi.root" t))
         (chezmoi-root (file-name-as-directory root))
         (source (expand-file-name "dot_config" root)))
    (unwind-protect
        (progn
          (with-temp-file source)
          (should (chezmoi-source-file-p source))
          (should-not (chezmoi-source-file-p
                       (concat (directory-file-name root) "X/dot_config"))))
      (delete-directory root t))))

(ert-deftest chezmoi-mode-from-path-ignores-buffers-without-files ()
  (with-temp-buffer
    (let ((chezmoi-root "/tmp/chezmoi/"))
      (should-not (chezmoi--mode-from-path)))))

(ert-deftest chezmoi-mode-from-path-can-be-disabled ()
  (let* ((root (make-temp-file "chezmoi.root" t))
         (chezmoi-root (file-name-as-directory root))
         (file (expand-file-name "dot_config" root))
         (mode-calls 0))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name file)
          (cl-letf (((symbol-function 'chezmoi-mode)
                     (lambda (&optional _arg) (cl-incf mode-calls))))
            (let ((chezmoi-auto-enable-mode nil))
              (chezmoi--mode-from-path))
            (should (= mode-calls 0))
            (let ((chezmoi-auto-enable-mode t))
              (chezmoi--mode-from-path))
            (should (= mode-calls 1))))
      (delete-directory root t))))

(ert-deftest chezmoi-template-uses-treesit-expression-spans ()
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert "{{ .chezmoi.os }}\n")
    (go-template-ts-mode)
    (let ((spans (chezmoi-template--treesit-expression-spans)))
      (should (= (length spans) 1))
      (should (equal (buffer-substring-no-properties
                      (caar spans) (cdar spans))
                     "{{ .chezmoi.os }}")))))

(ert-deftest chezmoi-template-finds-selector-inside-control-action ()
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert "{{ if .enabled }}\n{{ .path.workspace.qmk }}\n{{ end }}\n")
    (go-template-ts-mode)
    (let ((spans (chezmoi-template--treesit-expression-spans)))
      (should (= (length spans) 1))
      (should (equal (buffer-substring-no-properties
                      (caar spans) (cdar spans))
                     "{{ .path.workspace.qmk }}")))))

(ert-deftest chezmoi-template-after-change-is-debounced ()
  (with-temp-buffer
    (let ((chezmoi-template--buffer-displayed-p t)
          (chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-template--after-change nil nil nil)
            (should (timerp chezmoi-template--display-timer)))
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-mode-schedules-initial-template-display ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh.tmpl")
    (let ((chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-mode 1)
            (should (timerp chezmoi-template--display-timer))
            (chezmoi-mode -1)
            (should-not chezmoi-template--display-timer))
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-mode-does-not-force-full-buffer-fontification ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh.tmpl")
    (let ((chezmoi-template-display-delay 10)
          (font-lock-calls 0))
      (unwind-protect
          (cl-letf (((symbol-function 'font-lock-ensure)
                     (lambda (&rest _) (cl-incf font-lock-calls))))
            (chezmoi-mode 1)
            (chezmoi-mode -1)
            (should (= font-lock-calls 0)))
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-capf-completes-the-final-selector-segment ()
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert "{{ .chezmoi.o }}")
    (go-template-ts-mode)
    (goto-char (- (point-max) 3))
    (let ((data (make-hash-table :test #'equal))
          (chezmoi-data (make-hash-table :test #'equal)))
      (puthash "os" "darwin" chezmoi-data)
      (puthash "chezmoi" chezmoi-data data)
      (cl-letf (((symbol-function 'chezmoi-get-data) (lambda () data)))
        (pcase-let ((`(,beg ,end ,table . ,_) (chezmoi-capf)))
          (should (equal (buffer-substring-no-properties beg end) "o"))
          (should (equal (all-completions "o" table) '("os"))))))))

(provide 'chezmoi-test)
;;; chezmoi-test.el ends here
