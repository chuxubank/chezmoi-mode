;;; chezmoi-transient-test.el --- Tests for chezmoi-transient -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi-transient)

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

(ert-deftest chezmoi-transient-building-suffixes-does-not-toggle-mode ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/dot_config")
    (should-not chezmoi-mode)
    (transient-suffixes 'chezmoi-transient)
    (should-not chezmoi-mode)
    (transient-suffixes 'chezmoi-transient)
    (should-not chezmoi-mode)))

(ert-deftest chezmoi-transient-template-toggle-is-inapt-without-parser ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/dot_config/config.el")
    (setq-local chezmoi-mode t)
    (let ((suffix
           (cl-find-if
            (lambda (candidate)
              (eq (oref candidate command)
                  'chezmoi-template-buffer-display))
            (transient-suffixes 'chezmoi-transient))))
      (should suffix)
      (should (oref suffix inapt))
      (should chezmoi-mode))))

(ert-deftest chezmoi-transient-uses-polymode-base-buffer ()
  :tags '(integration)
  (skip-unless (and (locate-library "poly-any-go-template")
                    (treesit-ready-p 'gotmpl)))
  (require 'poly-any-go-template)
  (with-temp-buffer
    (setq buffer-file-name "/tmp/transient.sh.tmpl")
    (insert "echo {{ .chezmoi.os }}\n")
    (let ((chezmoi-template-mode-hook '(poly-any-go-template-mode))
          (chezmoi-template-display-delay 10)
          inner-buffer)
      (unwind-protect
          (cl-letf (((symbol-function 'chezmoi-template-execute)
                     (lambda (_) "darwin")))
            (chezmoi-mode 1)
            (chezmoi-template-buffer-display t)
            (pm-map-over-spans
             (lambda (span)
               (when (eq (car span) 'body)
                 (setq inner-buffer (current-buffer)))))
            (with-current-buffer inner-buffer
              (should (chezmoi-transient--template-buffer-p))
              (should (equal (chezmoi-transient--mode-description)
                             "Disable Chezmoi mode"))
              (should (equal (chezmoi-transient--display-description)
                             "Hide template values"))
              (call-interactively #'chezmoi-transient-toggle-mode))
            (should-not chezmoi-mode))
        (chezmoi-mode -1)
        (chezmoi-template--cancel-display-timer)))))

(provide 'chezmoi-transient-test)
;;; chezmoi-transient-test.el ends here
