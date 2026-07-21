;;; chezmoi-core-test.el --- Core tests for chezmoi -*- lexical-binding: t; no-native-compile: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi-mode)

(defconst chezmoi-test--loaded-transient-p
  (featurep 'transient))

(defconst chezmoi-test--loaded-integration-features
  (mapcar (lambda (feature)
            (cons feature (featurep feature)))
          '(dired ediff magit
            chezmoi-dired chezmoi-ediff chezmoi-magit)))

(defconst chezmoi-test--loaded-go-template-ts-mode-p
  (featurep 'go-template-ts-mode))

(defconst chezmoi-test--loaded-poly-any-go-template-p
  (featurep 'poly-any-go-template))

(ert-deftest chezmoi-mode-provides-renamed-feature ()
  (should (featurep 'chezmoi-mode))
  (should-not (featurep 'chezmoi)))

(ert-deftest chezmoi-does-not-load-poly-any-go-template ()
  (should-not chezmoi-test--loaded-poly-any-go-template-p))

(ert-deftest chezmoi-does-not-load-go-template-ts-mode ()
  (should-not chezmoi-test--loaded-go-template-ts-mode-p))

(ert-deftest chezmoi-does-not-load-transient ()
  (should-not chezmoi-test--loaded-transient-p))

(ert-deftest chezmoi-does-not-load-integration-libraries ()
  (dolist (entry chezmoi-test--loaded-integration-features)
    (should-not (cdr entry))))

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

(ert-deftest chezmoi-find-scripts-infers-shell-host-mode ()
  :tags '(integration)
  (skip-unless (and (locate-library "poly-any-go-template")
                    (treesit-ready-p 'gotmpl)))
  (require 'poly-any-go-template)
  (let* ((directory (make-temp-file "chezmoi-script" t))
         (script (expand-file-name "run_once_setup.sh.tmpl" directory))
         (chezmoi-template-mode-hook '(poly-any-go-template-mode))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file script
            (insert "#!/bin/sh\necho {{ .chezmoi.os }}\n"))
          (setq buffer (chezmoi-find-scripts script))
          (with-current-buffer buffer
            (should (eq major-mode 'sh-mode))
            (should chezmoi-mode)
            (should (chezmoi-template-buffer-p))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory directory t))))

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

(provide 'chezmoi-core-test)
;;; chezmoi-core-test.el ends here
