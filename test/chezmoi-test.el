;;; chezmoi-test.el --- Tests for chezmoi -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi-mode)

(defconst chezmoi-test--loaded-transient-p
  (featurep 'transient))

(defconst chezmoi-test--main-extension-bindings
  (mapcar (lambda (command)
            (cons command (fboundp command)))
          '(chezmoi-dired-add-marked-files
            chezmoi-ediff
            chezmoi-ediff-merge
            chezmoi-magit-status)))

(require 'chezmoi-ediff)

(defconst chezmoi-test--loaded-go-template-ts-mode-p
  (featurep 'go-template-ts-mode))

(defconst chezmoi-test--loaded-poly-any-go-template-p
  (featurep 'poly-any-go-template))

(when (getenv "CHEZMOI_TEST_INTEGRATION")
  (require 'go-template-ts-mode nil t))

(ert-deftest chezmoi-mode-provides-renamed-feature ()
  (should (featurep 'chezmoi-mode))
  (should-not (featurep 'chezmoi)))

(ert-deftest chezmoi-does-not-load-poly-any-go-template ()
  (should-not chezmoi-test--loaded-poly-any-go-template-p))

(ert-deftest chezmoi-does-not-load-go-template-ts-mode ()
  (should-not chezmoi-test--loaded-go-template-ts-mode-p))

(ert-deftest chezmoi-does-not-load-transient ()
  (should-not chezmoi-test--loaded-transient-p))

(ert-deftest chezmoi-does-not-autoload-extension-commands ()
  (dolist (entry chezmoi-test--main-extension-bindings)
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

(ert-deftest chezmoi-ediff-startup-error-does-not-leak-advice ()
  (let ((chezmoi-ediff-template-use-ediff3 nil))
    (unwind-protect
        (cl-letf (((symbol-function 'chezmoi-find)
                   (lambda (_) "/tmp/source.tmpl"))
                  ((symbol-function 'chezmoi-encrypted-p) #'ignore)
                  ((symbol-function 'chezmoi-template-file-p)
                   (lambda (_) t))
                  ((symbol-function 'ediff)
                   (lambda (&rest _) (error "Ediff startup failed"))))
          (should-error (chezmoi-ediff "/tmp/target"))
          (should-not
           (advice-member-p #'chezmoi-ediff--ediff-get-region-contents
                            'ediff-get-region-contents)))
      (advice-remove 'ediff-get-region-contents
                     #'chezmoi-ediff--ediff-get-region-contents))))

(ert-deftest chezmoi-ediff-post-startup-error-does-not-leak-session ()
  (let ((chezmoi-ediff-template-use-ediff3 nil)
        control)
    (unwind-protect
        (cl-letf (((symbol-function 'chezmoi-find)
                   (lambda (_) "/tmp/source.tmpl"))
                  ((symbol-function 'chezmoi-encrypted-p) #'ignore)
                  ((symbol-function 'chezmoi-template-file-p)
                   (lambda (_) t))
                  ((symbol-function 'ediff)
                   (lambda (_source _target &optional startup-hooks)
                     (setq control
                           (generate-new-buffer
                            " *chezmoi-ediff-control*"))
                     (with-current-buffer control
                       (mapc #'funcall startup-hooks))
                     (error "Ediff failed after startup"))))
          (should-error (chezmoi-ediff "/tmp/target"))
          (should-not
           (advice-member-p #'chezmoi-ediff--ediff-get-region-contents
                            'ediff-get-region-contents)))
      (when (buffer-live-p control)
        (kill-buffer control))
      (advice-remove 'ediff-get-region-contents
                     #'chezmoi-ediff--ediff-get-region-contents))))

(ert-deftest chezmoi-ediff-failed-session-is-inert-while-another-is-active ()
  (let ((chezmoi-ediff-template-use-ediff3 nil)
        (chezmoi-ediff-force-overwrite t)
        (ediff-cleanup-hook nil)
        controls variant-buffers failed-control
        (ediff-calls 0)
        (execute-calls 0)
        (write-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'chezmoi-find)
                   (lambda (target) (concat target ".tmpl")))
                  ((symbol-function 'chezmoi-encrypted-p) #'ignore)
                  ((symbol-function 'chezmoi-template-file-p)
                   (lambda (_) t))
                  ((symbol-function 'chezmoi-template-execute)
                   (lambda (_)
                     (cl-incf execute-calls)
                     "rendered"))
                  ((symbol-function 'chezmoi-write)
                   (lambda (&rest _)
                     (cl-incf write-calls)))
                  ((symbol-function 'ediff)
                   (lambda (source _target &optional startup-hooks)
                     (cl-incf ediff-calls)
                     (let ((source-buffer
                            (generate-new-buffer
                             " *chezmoi-ediff-source*"))
                           (target-buffer
                            (generate-new-buffer
                             " *chezmoi-ediff-target*"))
                           (control
                            (generate-new-buffer
                             " *chezmoi-ediff-control*")))
                       (with-current-buffer source-buffer
                         (setq buffer-file-name source)
                         (insert "raw"))
                       (with-current-buffer target-buffer
                         (insert "raw"))
                       (setq variant-buffers
                             (append variant-buffers
                                     (list source-buffer target-buffer)))
                       (setq controls (append controls (list control)))
                       (with-current-buffer control
                         (setq-local ediff-buffer-A source-buffer)
                         (setq-local ediff-buffer-B target-buffer)
                         (mapc #'funcall startup-hooks))
                       (set-buffer control)
                       (when (= ediff-calls 2)
                         (setq failed-control control)
                         (error "Ediff failed after startup"))
                       control))))
          (chezmoi-ediff "/tmp/active-target")
          (should-error (chezmoi-ediff "/tmp/failed-target"))
          (should
           (advice-member-p #'chezmoi-ediff--ediff-get-region-contents
                            'ediff-get-region-contents))
          (with-current-buffer failed-control
            (should-not chezmoi-ediff--source-file)
            (should-not chezmoi-ediff--template-source-file)
            (should-not (memq #'chezmoi-ediff--ediff-cleanup-hook
                              ediff-cleanup-hook))
            (should-not
             (memq #'chezmoi-ediff--unregister-template-session
                   kill-buffer-hook))
            (should (equal
                     (ediff-get-region-contents
                      0 'A failed-control 1
                      (with-current-buffer ediff-buffer-A (point-max)))
                     "raw"))
            (run-hooks 'ediff-cleanup-hook))
          (should (= execute-calls 0))
          (should (= write-calls 0)))
      (let ((chezmoi-ediff-force-overwrite nil))
        (dolist (control controls)
          (when (buffer-live-p control)
            (with-current-buffer control
              (run-hooks 'ediff-cleanup-hook))
            (when (buffer-live-p control)
              (kill-buffer control)))))
      (dolist (buffer variant-buffers)
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (advice-remove 'ediff-get-region-contents
                     #'chezmoi-ediff--ediff-get-region-contents))))

(ert-deftest chezmoi-ediff-keeps-advice-until-last-template-session-quits ()
  (let ((chezmoi-ediff-template-use-ediff3 nil)
        (chezmoi-ediff-force-overwrite nil)
        (ediff-cleanup-hook nil)
        controls)
    (unwind-protect
        (cl-letf (((symbol-function 'chezmoi-find)
                   (lambda (target) (concat target ".tmpl")))
                  ((symbol-function 'chezmoi-encrypted-p) #'ignore)
                  ((symbol-function 'chezmoi-template-file-p)
                   (lambda (_) t))
                  ((symbol-function 'ediff)
                   (lambda (&rest args)
                     (let ((control (generate-new-buffer
                                     " *chezmoi-ediff-control*")))
                       (setq controls (append controls (list control)))
                       (set-buffer control)
                       (mapc #'funcall (nth 2 args))
                       control))))
          (chezmoi-ediff "/tmp/target-one")
          (chezmoi-ediff "/tmp/target-two")
          (should
           (advice-member-p #'chezmoi-ediff--ediff-get-region-contents
                            'ediff-get-region-contents))
          (with-current-buffer (car controls)
            (run-hooks 'ediff-cleanup-hook))
          (should
           (advice-member-p #'chezmoi-ediff--ediff-get-region-contents
                            'ediff-get-region-contents))
          (with-current-buffer (cadr controls)
            (run-hooks 'ediff-cleanup-hook))
          (should-not
           (advice-member-p #'chezmoi-ediff--ediff-get-region-contents
                            'ediff-get-region-contents)))
      (advice-remove 'ediff-get-region-contents
                     #'chezmoi-ediff--ediff-get-region-contents)
      (dolist (control controls)
        (when (buffer-live-p control)
          (kill-buffer control))))))

(ert-deftest chezmoi-ediff-renders-only-template-session-source-regions ()
  (let ((chezmoi-ediff-template-use-ediff3 nil)
        (chezmoi-ediff-force-overwrite nil)
        (ediff-cleanup-hook nil)
        controls source-buffers results
        (execute-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'chezmoi-find)
                   (lambda (target)
                     (let* ((template-p (string-match-p "template" target))
                            (source (concat target
                                            (if template-p ".tmpl" ".txt")))
                            (buffer (generate-new-buffer
                                     " *chezmoi-ediff-source*")))
                       (with-current-buffer buffer
                         (setq buffer-file-name source)
                         (insert (if template-p "{{ .value }}" "plain")))
                       (push buffer source-buffers)
                       (set-buffer buffer)
                       source)))
                  ((symbol-function 'chezmoi-encrypted-p) #'ignore)
                  ((symbol-function 'chezmoi-template-file-p)
                   (lambda (source) (string-suffix-p ".tmpl" source)))
                  ((symbol-function 'chezmoi-template-execute)
                   (lambda (_)
                     (cl-incf execute-calls)
                     "rendered"))
                  ((symbol-function 'ediff)
                   (lambda (source _target &optional startup-hooks)
                     (let ((control (generate-new-buffer
                                     " *chezmoi-ediff-control*"))
                           (source-buffer (get-file-buffer source)))
                       (with-current-buffer control
                         (setq-local ediff-buffer-A source-buffer)
                         (setq-local ediff-buffer-B
                                     (generate-new-buffer
                                      " *chezmoi-ediff-target*"))
                         (mapc #'funcall startup-hooks)
                         (push (ediff-get-region-contents
                                0 'A control 1
                                (with-current-buffer source-buffer
                                  (point-max)))
                               results))
                       (push control controls)
                       (set-buffer control)
                       control))))
          (chezmoi-ediff "/tmp/template-target")
          (chezmoi-ediff "/tmp/plain-target")
          (should (equal (nreverse results) '("rendered" "plain")))
          (should (= execute-calls 1)))
      (dolist (control controls)
        (when (buffer-live-p control)
          (with-current-buffer control
            (run-hooks 'ediff-cleanup-hook)
            (when (buffer-live-p ediff-buffer-B)
              (kill-buffer ediff-buffer-B)))
          (when (buffer-live-p control)
            (kill-buffer control))))
      (dolist (buffer source-buffers)
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (advice-remove 'ediff-get-region-contents
                     #'chezmoi-ediff--ediff-get-region-contents))))

(ert-deftest chezmoi-ediff3-cleans-rendered-temp-on-cleanup ()
  (let ((source-file
         (make-temp-file "chezmoi-ediff-source" nil ".tmpl" "{{ .value }}"))
        (chezmoi-ediff-template-use-ediff3 t)
        (ediff-cleanup-hook nil)
        control rendered-file)
    (unwind-protect
        (cl-letf (((symbol-function 'chezmoi-find)
                   (lambda (_) source-file))
                  ((symbol-function 'chezmoi-encrypted-p) #'ignore)
                  ((symbol-function 'chezmoi-template-file-p)
                   (lambda (_) t))
                  ((symbol-function 'chezmoi-template-execute)
                   (lambda (_) "rendered"))
                  ((symbol-function 'ediff3)
                   (lambda (file-a _file-b _file-c &optional startup-hooks)
                     (setq rendered-file file-a)
                     (setq control
                           (generate-new-buffer
                            " *chezmoi-ediff3-control*"))
                     (with-current-buffer control
                       (mapc #'funcall startup-hooks))
                     control)))
          (chezmoi-ediff "/tmp/target")
          (should (file-exists-p rendered-file))
          (with-current-buffer control
            (run-hooks 'ediff-cleanup-hook))
          (should-not (file-exists-p rendered-file)))
      (when (buffer-live-p control)
        (kill-buffer control))
      (when (and rendered-file (file-exists-p rendered-file))
        (delete-file rendered-file))
      (delete-file source-file))))

(ert-deftest chezmoi-ediff3-startup-error-cleans-rendered-temp ()
  (let ((source-file
         (make-temp-file "chezmoi-ediff-source" nil ".tmpl" "{{ .value }}"))
        (chezmoi-ediff-template-use-ediff3 t)
        rendered-file)
    (unwind-protect
        (cl-letf (((symbol-function 'chezmoi-find)
                   (lambda (_) source-file))
                  ((symbol-function 'chezmoi-encrypted-p) #'ignore)
                  ((symbol-function 'chezmoi-template-file-p)
                   (lambda (_) t))
                  ((symbol-function 'chezmoi-template-execute)
                   (lambda (_) "rendered"))
                  ((symbol-function 'ediff3)
                   (lambda (file-a _file-b _file-c &optional _startup-hooks)
                     (setq rendered-file file-a)
                     (error "Ediff3 startup failed"))))
          (should-error (chezmoi-ediff "/tmp/target"))
          (should-not (file-exists-p rendered-file)))
      (when (and rendered-file (file-exists-p rendered-file))
        (delete-file rendered-file))
      (delete-file source-file))))

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
        (chezmoi-mode -1)
        (should-not (memq #'chezmoi--write-after-save after-save-hook))
        (should-not (memq #'chezmoi-capf completion-at-point-functions)))
      (should activated))))

(ert-deftest chezmoi-mode-non-template-only-initializes-synchronization ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/dot_config/config.el")
    (let ((chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-mode 1)
            (should (memq #'chezmoi--write-after-save after-save-hook))
            (should-not (memq #'chezmoi-capf
                              completion-at-point-functions))
            (should-not (memq #'chezmoi-template--after-change
                              after-change-functions))
            (should-not chezmoi-template--display-timer))
        (chezmoi-mode -1)
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-template-buffer-display-ignores-non-template-buffer ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/dot_config/config.el")
    (setq-local chezmoi-mode t)
    (let ((chezmoi-template-display-delay 10))
      (chezmoi-template-buffer-display t)
      (should-not chezmoi-template--buffer-displayed-p)
      (should-not (memq #'chezmoi-template--after-change
                        after-change-functions))
      (should-not chezmoi-template--display-timer))))

(ert-deftest chezmoi-template-removes-display-properties-from-buffer-start ()
  (with-temp-buffer
    (insert "first middle second")
    (chezmoi-template--put-display-value 1 6 "one")
    (chezmoi-template--put-display-value 14 20 "two")
    (chezmoi-template--funcall-over-display-properties
     #'chezmoi-template--remove-display-value nil (current-buffer))
    (should-not (text-property-any (point-min) (point-max) 'chezmoi t))
    (should-not (text-property-not-all (point-min) (point-max) 'display nil))))

(ert-deftest chezmoi-mode-template-without-parser-only-initializes-sync ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/config.tmpl")
    (let ((chezmoi-template-mode-hook nil)
          (chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-mode 1)
            (should (memq #'chezmoi--write-after-save after-save-hook))
            (should-not (memq #'chezmoi-capf
                              completion-at-point-functions))
            (should-not (memq #'chezmoi-template--after-change
                              after-change-functions))
            (should-not chezmoi-template--display-timer))
        (chezmoi-mode -1)
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-mode-has-lighter ()
  (should (equal (cdr (assq 'chezmoi-mode minor-mode-alist))
                 '(" Chezmoi"))))

(ert-deftest chezmoi-template-display-is-enabled-by-default ()
  (should (default-value 'chezmoi-template-display-p)))

(ert-deftest chezmoi-mode-registers-capf-after-major-mode-change ()
  :tags '(integration)
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

(ert-deftest chezmoi-template-restores-removed-completion-hook ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (go-template-ts-mode)
    (unwind-protect
        (progn
          (should (chezmoi-template-set-completion t))
          (remove-hook 'completion-at-point-functions #'chezmoi-capf t)
          (should-not (memq #'chezmoi-capf
                            completion-at-point-functions))
          (should (chezmoi-template-set-completion t))
          (should (memq #'chezmoi-capf
                        completion-at-point-functions)))
      (chezmoi-template-set-completion nil))))

(ert-deftest chezmoi-template-file-p-recognizes-template-sources ()
  (let* ((root (make-temp-file "chezmoi.root" t))
         (chezmoi-root (file-name-as-directory root))
         (templates (expand-file-name ".chezmoitemplates" root))
         (unrelated (expand-file-name ".chezmoitemplates-old" root))
         (files (mapcar (lambda (name) (expand-file-name name root))
                        '("run.sh.tmpl" "modify_dot_config"
                          "run.sh.tmpl.bak"))))
    (unwind-protect
        (progn
          (make-directory templates)
          (make-directory unrelated)
          (dolist (file (append files
                                (list (expand-file-name "Brewfile" templates)
                                      (expand-file-name "script.sh" templates)
                                      (expand-file-name "Brewfile" unrelated))))
            (with-temp-file file))
          (should (chezmoi-template-file-p (nth 0 files)))
          (should (chezmoi-template-file-p (nth 1 files)))
          (should (chezmoi-template-file-p
                   (expand-file-name "Brewfile" templates)))
          (should (chezmoi-template-file-p
                   (expand-file-name "script.sh" templates)))
          (should-not (chezmoi-template-file-p
                       (expand-file-name "Brewfile" unrelated)))
          (should-not (chezmoi-template-file-p (nth 2 files))))
      (delete-directory root t))))

(ert-deftest chezmoi-normalizes-template-host-filename ()
  (let* ((root (make-temp-file "chezmoi.root" t))
         (chezmoi-root (file-name-as-directory root))
         (source (expand-file-name "dot_zprofile" root)))
    (unwind-protect
        (progn
          (with-temp-file source)
          (should (equal
                   (chezmoi-template-normalize-host-filename source)
                   (expand-file-name ".zprofile" root))))
      (delete-directory root t))))

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
  :tags '(integration)
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
  :tags '(integration)
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

(ert-deftest chezmoi-template-buffer-display-writes-after-polymode-traversal ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert "{{ .chezmoi.os }}")
    (go-template-ts-mode)
    (setq-local polymode-mode t)
    (let (modified-during-traversal)
      (cl-letf (((symbol-function 'pm-map-over-spans)
                 (lambda (function &rest _)
                   (funcall function
                            (list nil (point-min) (point-max)))
                   (setq modified-during-traversal
                         (text-property-any
                          (point-min) (point-max) 'chezmoi t))))
                ((symbol-function 'chezmoi-template-execute)
                 (lambda (_) "darwin")))
        (chezmoi-template-buffer-display t))
      (should-not modified-during-traversal)
      (should (equal (get-text-property (point-min) 'display)
                     "darwin")))))

(ert-deftest chezmoi-mode-supports-real-polymode-template-buffers ()
  :tags '(integration)
  (skip-unless (and (locate-library "poly-any-go-template")
                    (treesit-ready-p 'gotmpl)))
  (require 'poly-any-go-template)
  (with-temp-buffer
    (setq buffer-file-name "/tmp/run_once_setup.sh.tmpl")
    (insert "#!/bin/sh\necho {{ .chezmoi.o }}\n")
    (let* ((chezmoi-template-mode-hook '(poly-any-go-template-mode))
           (chezmoi-template-display-delay 10)
           (data (make-hash-table :test #'equal))
           (chezmoi-data (make-hash-table :test #'equal)))
      (puthash "os" "darwin" chezmoi-data)
      (puthash "chezmoi" chezmoi-data data)
      (unwind-protect
          (cl-letf (((symbol-function 'chezmoi-get-data)
                     (lambda () data))
                    ((symbol-function 'chezmoi-template-execute)
                     (lambda (_) "darwin")))
            (chezmoi-mode 1)
            (should (eq major-mode 'sh-mode))
            (should (chezmoi-template-buffer-p))
            (should (timerp chezmoi-template--display-timer))
            (let (inner-capf candidates)
              (pm-map-over-spans
               (lambda (span)
                 (when (eq (car span) 'body)
                   (setq inner-capf
                         (memq #'chezmoi-capf
                               completion-at-point-functions))
                   (goto-char (nth 1 span))
                   (search-forward ".chezmoi.o" (nth 2 span))
                   (pcase-let ((`(,beg ,end ,table . ,_)
                                (chezmoi-capf)))
                     (should (equal
                              (buffer-substring-no-properties beg end)
                              "o"))
                     (setq candidates (all-completions "o" table))))))
              (should inner-capf)
              (should (equal candidates '("os"))))
            (chezmoi-template-buffer-display t)
            (goto-char (point-min))
            (search-forward "{{")
            (should (equal (get-text-property (match-beginning 0) 'display)
                           "darwin"))
            (let (inner-buffer)
              (pm-map-over-spans
               (lambda (span)
                 (when (eq (car span) 'body)
                   (setq inner-buffer (current-buffer)))))
              (should
               (memq #'chezmoi-template--after-change
                     (buffer-local-value 'after-change-functions
                                         inner-buffer)))
              (with-current-buffer inner-buffer
                (goto-char (nth 2 (pm-innermost-span)))
                (insert " "))
              (should (timerp chezmoi-template--display-timer))
              (chezmoi-template--cancel-display-timer)
              (with-current-buffer inner-buffer
                (call-interactively #'chezmoi-template-buffer-display))
              (should-not chezmoi-template--buffer-displayed-p)
              (goto-char (point-min))
              (search-forward "{{")
              (should-not (get-text-property (match-beginning 0) 'display))
              (chezmoi-mode -1)
              (should-not
               (memq #'chezmoi-capf
                     (buffer-local-value
                      'completion-at-point-functions inner-buffer)))
              (should-not
               (memq #'chezmoi-template--after-change
                     (buffer-local-value
                      'after-change-functions inner-buffer)))))
        (chezmoi-mode -1)
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-mode-restores-hooks-in-recreated-polymode-buffer ()
  :tags '(integration)
  (skip-unless (and (locate-library "poly-any-go-template")
                    (treesit-ready-p 'gotmpl)))
  (require 'poly-any-go-template)
  (with-temp-buffer
    (setq buffer-file-name "/tmp/recreate.sh.tmpl")
    (insert "echo {{ .chezmoi.os }}\n")
    (let ((chezmoi-template-mode-hook '(poly-any-go-template-mode))
          (chezmoi-template-display-p nil)
          first-inner second-inner)
      (unwind-protect
          (progn
            (chezmoi-mode 1)
            (pm-map-over-spans
             (lambda (span)
               (when (eq (car span) 'body)
                 (setq first-inner (current-buffer)))))
            (should (buffer-live-p first-inner))
            (kill-buffer first-inner)
            (pm-map-over-spans
             (lambda (span)
               (when (eq (car span) 'body)
                 (setq second-inner (current-buffer)))))
            (should (buffer-live-p second-inner))
            (should-not (eq first-inner second-inner))
            (should (memq #'chezmoi-capf
                          (buffer-local-value
                           'completion-at-point-functions second-inner)))
            (should-not
             (memq first-inner chezmoi-template--completion-buffers)))
        (chezmoi-mode -1)))))

(ert-deftest chezmoi-template-buffer-display-executes-multiple-selectors-once ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert (concat "{{ .chezmoi.os }} {{ .enabled }} "
                    "{{ .count }} {{ .missing }}"))
    (go-template-ts-mode)
    (let ((external-calls 0))
      (cl-letf (((symbol-function 'chezmoi-template-execute)
                 (lambda (template)
                   (cl-incf external-calls)
                   (cond
                    ((string-match-p
                      (regexp-quote "{{ .missing }}") template)
                     "chezmoi: map has no entry for key missing")
                    ((string-match-p (regexp-quote "{{ dig ") template)
                     (replace-regexp-in-string
                      "{{ dig [^}]+}}"
                      (lambda (action)
                        (save-match-data
                          (cond
                           ((string-match-p
                             (regexp-quote "\"chezmoi\" \"os\"") action)
                            "darwin")
                           ((string-match-p
                             (regexp-quote "\"enabled\"") action)
                            "true")
                           ((string-match-p
                             (regexp-quote "\"count\"") action)
                            "42")
                           ((string-match
                             "\"\\([^\"]+\\)\" \\. }}\\'" action)
                            (match-string 1 action)))))
                      template t t))
                    (t template)))))
        (chezmoi-template-buffer-display t))
      (should (= external-calls 1))
      (goto-char (point-min))
      (should (equal (get-text-property (point) 'display) "darwin"))
      (search-forward "{{ .enabled }}")
      (should (equal (get-text-property (match-beginning 0) 'display)
                     "true"))
      (search-forward "{{ .count }}")
      (should (equal (get-text-property (match-beginning 0) 'display)
                     "42"))
      (search-forward "{{ .missing }}")
      (should-not (get-text-property (match-beginning 0) 'display)))))

(ert-deftest chezmoi-template-buffer-display-handles-single-missing-selector ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert "{{ .missing }}")
    (go-template-ts-mode)
    (let ((execute-calls 0))
      (cl-letf (((symbol-function 'chezmoi-template-execute)
                 (lambda (template)
                   (cl-incf execute-calls)
                   (if (string-match-p
                        (regexp-quote "{{ .missing }}") template)
                       (error "Unsafe missing selector lookup")
                     (when (string-match
                            "\"\\([^\"]+\\)\" \\. }}\\'" template)
                       (match-string 1 template))))))
        (chezmoi-template-buffer-display t))
      (should (= execute-calls 1))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest chezmoi-template-display-does-not-force-fontification ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert "{{ .chezmoi.os }}")
    (go-template-ts-mode)
    (set-buffer-modified-p nil)
    (let (font-lock-calls)
      (cl-letf (((symbol-function 'chezmoi-template-execute)
                 (lambda (_) "darwin"))
                ((symbol-function 'font-lock-flush)
                 (lambda (&rest _) (push 'flush font-lock-calls)))
                ((symbol-function 'font-lock-ensure)
                 (lambda (&rest _) (push 'ensure font-lock-calls))))
        (chezmoi-template-buffer-display t)
        (chezmoi-template-buffer-display nil))
      (should-not font-lock-calls)
      (should-not (buffer-modified-p)))))

(ert-deftest chezmoi-template-after-change-is-debounced ()
  (with-temp-buffer
    (let ((chezmoi-template--buffer-displayed-p t)
          (chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-template--after-change nil nil nil)
            (should (timerp chezmoi-template--display-timer)))
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-template-schedule-requires-chezmoi-mode ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (go-template-ts-mode)
    (let ((chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-template-schedule-buffer-display)
            (should-not chezmoi-template--display-timer))
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-template-schedule-requires-display-enabled ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (go-template-ts-mode)
    (setq-local chezmoi-mode t)
    (let ((chezmoi-template-display-p nil)
          (chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-template-schedule-buffer-display)
            (should-not chezmoi-template--display-timer))
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-template-schedule-requires-parser ()
  (with-temp-buffer
    (setq-local chezmoi-mode t)
    (let ((chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-template-schedule-buffer-display)
            (should-not chezmoi-template--display-timer))
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-mode-schedules-initial-template-display ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh.tmpl")
    (go-template-ts-mode)
    (let ((chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-mode 1)
            (should (timerp chezmoi-template--display-timer))
            (chezmoi-mode -1)
            (should-not chezmoi-template--display-timer))
        (chezmoi-template--cancel-display-timer)))))

(ert-deftest chezmoi-mode-display-disabled-does-not-install-refresh ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh.tmpl")
    (go-template-ts-mode)
    (let ((chezmoi-template-display-p nil)
          (chezmoi-template-display-delay 10))
      (unwind-protect
          (progn
            (chezmoi-mode 1)
            (should (memq #'chezmoi-capf
                          completion-at-point-functions))
            (should-not (memq #'chezmoi-template--after-change
                              after-change-functions))
            (should-not chezmoi-template--display-timer))
        (chezmoi-mode -1)
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
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert "{{ .chezmoi.o }}")
    (go-template-ts-mode)
    (goto-char (- (point-max) 3))
    (let ((data (make-hash-table :test #'equal))
          (chezmoi-data (make-hash-table :test #'equal))
          (data-calls 0))
      (puthash "os" "darwin" chezmoi-data)
      (puthash "chezmoi" chezmoi-data data)
      (let ((chezmoi-template-completion-cache-duration 60))
        (cl-letf (((symbol-function 'chezmoi-get-data)
                   (lambda ()
                     (cl-incf data-calls)
                     data)))
          (pcase-let ((`(,beg ,end ,table . ,_) (chezmoi-capf)))
            (should (equal (buffer-substring-no-properties beg end) "o"))
            (should (equal (all-completions "o" table) '("os"))))
          (pcase-let ((`(,_beg ,_end ,table . ,_) (chezmoi-capf)))
            (should (equal (all-completions "o" table) '("os"))))
          (should (= data-calls 1)))))))

(ert-deftest chezmoi-capf-completes-root-selector-fields ()
  :tags '(integration)
  (skip-unless (and (fboundp 'go-template-ts-mode)
                    (treesit-ready-p 'gotmpl)))
  (with-temp-buffer
    (insert "{{ .o }}")
    (go-template-ts-mode)
    (search-backward ".o")
    (forward-char 2)
    (let ((data (make-hash-table :test #'equal)))
      (puthash "os" "darwin" data)
      (cl-letf (((symbol-function 'chezmoi-get-data) (lambda () data)))
        (pcase-let ((`(,beg ,end ,table . ,_) (chezmoi-capf)))
          (should (equal (buffer-substring-no-properties beg end) "o"))
          (should (equal (all-completions "o" table) '("os"))))))))

(provide 'chezmoi-test)
;;; chezmoi-test.el ends here
