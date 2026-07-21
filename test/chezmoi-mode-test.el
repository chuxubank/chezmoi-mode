;;; chezmoi-mode-test.el --- Mode tests for chezmoi -*- lexical-binding: t; no-native-compile: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi-mode)

(when (getenv "CHEZMOI_TEST_INTEGRATION")
  (require 'go-template-ts-mode nil t))

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

(provide 'chezmoi-mode-test)
;;; chezmoi-mode-test.el ends here
