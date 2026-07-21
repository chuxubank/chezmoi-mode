;;; chezmoi-host-mode-test.el --- Chezmoi host-mode integration tests -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi-mode)
(require 'poly-any-go-template)

(defconst chezmoi-host-mode-test--template-file
  (expand-file-name
   "../chezmoi-template.el"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the literal `chezmoi-template.el' package source.")

(defconst chezmoi-host-mode-test--source
  (concat "(defun custom-message ()\n"
          "  (message \"configured\"))\n"
          "{{ if .enabled }}\n"
          "(message \"enabled\")\n"
          "{{ end }}\n")
  "Emacs Lisp host source containing Go Template actions.")

(defun chezmoi-host-mode-test--kill-buffer (buffer)
  "Kill BUFFER without prompting about test fixture changes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (set-buffer-modified-p nil))
    (kill-buffer buffer)))

(defun chezmoi-host-mode-test--assert-elisp-font-lock ()
  "Assert that the current buffer retains Emacs Lisp fontification."
  (font-lock-ensure (point-min) (point-max))
  (goto-char (point-min))
  (search-forward "defun")
  (should (eq (get-text-property (1- (point)) 'face)
              'font-lock-keyword-face)))

(defun chezmoi-host-mode-test--assert-chezmoi-template-buffer ()
  "Assert that the current buffer is an Emacs Lisp Chezmoi polymode."
  (should (eq major-mode 'emacs-lisp-mode))
  (should (bound-and-true-p polymode-mode))
  (should chezmoi-mode)
  (should (chezmoi-template-buffer-p))
  (chezmoi-host-mode-test--assert-elisp-font-lock))

(ert-deftest chezmoi-host-mode-direct-visit-infers-elisp ()
  :tags '(integration)
  (skip-unless (treesit-ready-p 'gotmpl))
  (let* ((directory (make-temp-file "chezmoi-host-mode" t))
         (chezmoi-root (file-name-as-directory directory))
         (source (expand-file-name "modify_custom.el" chezmoi-root))
         (chezmoi-auto-enable-mode t)
         (chezmoi-template-display-p nil)
         (poly-any-go-template-extra-file-name-rules
          '(chezmoi-template-source-file-p))
         (poly-any-template-host-filename-functions
          '(chezmoi-template-normalize-host-filename))
         (chezmoi-template-mode-hook '(poly-any-go-template-mode))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file source
            (insert chezmoi-host-mode-test--source))
          (setq buffer (find-file-noselect source))
          (with-current-buffer buffer
            (chezmoi-host-mode-test--assert-chezmoi-template-buffer)))
      (chezmoi-host-mode-test--kill-buffer buffer)
      (delete-directory directory t))))

(ert-deftest chezmoi-host-mode-chezmoi-find-infers-elisp ()
  :tags '(integration)
  (skip-unless (treesit-ready-p 'gotmpl))
  (let* ((directory (make-temp-file "chezmoi-host-mode" t))
         (chezmoi-root (file-name-as-directory directory))
         (source (expand-file-name "modify_custom.el" chezmoi-root))
         (target (expand-file-name "custom.el"
                                   (make-temp-file "chezmoi-target" t)))
         (target-directory (file-name-directory target))
         (chezmoi-auto-enable-mode t)
         (chezmoi-template-display-p nil)
         (poly-any-go-template-extra-file-name-rules
          '(chezmoi-template-source-file-p))
         (poly-any-template-host-filename-functions
          '(chezmoi-template-normalize-host-filename))
         (chezmoi-template-mode-hook '(poly-any-go-template-mode))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file source
            (insert chezmoi-host-mode-test--source))
          (cl-letf (((symbol-function 'chezmoi-source-file)
                     (lambda (_) source)))
            (chezmoi-find target)
            (setq buffer (current-buffer)))
          (with-current-buffer buffer
            (chezmoi-host-mode-test--assert-chezmoi-template-buffer)))
      (chezmoi-host-mode-test--kill-buffer buffer)
      (delete-directory directory t)
      (delete-directory target-directory t))))

(ert-deftest chezmoi-host-mode-upgrades-pure-go-template-mode ()
  :tags '(integration)
  (skip-unless (treesit-ready-p 'gotmpl))
  (let* ((directory (make-temp-file "chezmoi-host-mode" t))
         (chezmoi-root (file-name-as-directory directory))
         (source (expand-file-name "dot_zprofile.tmpl" chezmoi-root))
         (chezmoi-template-display-p nil)
         (poly-any-template-host-filename-functions
          '(chezmoi-template-normalize-host-filename))
         (chezmoi-template-mode-hook '(poly-any-go-template-mode)))
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name source)
          (insert "export PATH={{ .path }}\n")
          (go-template-ts-mode)
          (should-not (bound-and-true-p polymode-mode))
          (chezmoi-mode 1)
          (should (eq major-mode 'sh-mode))
          (should (bound-and-true-p polymode-mode))
          (should chezmoi-mode)
          (should (chezmoi-template-buffer-p)))
      (delete-directory directory t))))

(ert-deftest chezmoi-host-mode-literal-template-library-stays-elisp ()
  :tags '(integration)
  (let ((chezmoi-root nil)
        buffer)
    (unwind-protect
        (progn
          (setq buffer
                (find-file-noselect
                 chezmoi-host-mode-test--template-file))
          (with-current-buffer buffer
            (should (eq major-mode 'emacs-lisp-mode))
            (should-not (bound-and-true-p polymode-mode))
            (chezmoi-host-mode-test--assert-elisp-font-lock)))
      (chezmoi-host-mode-test--kill-buffer buffer))))

(provide 'chezmoi-host-mode-test)
;;; chezmoi-host-mode-test.el ends here
