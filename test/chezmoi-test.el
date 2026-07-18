;;; chezmoi-test.el --- Tests for chezmoi -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi)

(ert-deftest chezmoi-find-scripts-is-command ()
  (should (commandp #'chezmoi-find-scripts)))

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

(ert-deftest chezmoi-mode-initializes-template-module ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh.tmpl")
    (let ((activated nil)
          (changed-calls 0))
      (cl-letf (((symbol-function 'chezmoi-changed-p)
                 (lambda (&rest _) (cl-incf changed-calls) nil))
                ((symbol-function 'chezmoi-template--activate-go-template-mode)
                 (lambda () (setq activated t)))
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
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/modify_dot_config")
    (let ((chezmoi-root "/tmp/chezmoi/"))
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

(ert-deftest chezmoi-activates-template-polymode-for-host-buffer ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/modify_dot_config")
    (sh-mode)
    (let ((chezmoi-root "/tmp/chezmoi/")
          (activated nil))
      (setq-local chezmoi-mode t)
      (cl-letf (((symbol-function 'poly-any-go-template-mode)
                 (lambda () (setq activated t))))
        (chezmoi-template--activate-go-template-mode))
      (should activated))))

(ert-deftest chezmoi-uses-go-template-mode-for-plain-template ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/modify_dot_config")
    (let ((chezmoi-root "/tmp/chezmoi/"))
      (setq-local chezmoi-mode t)
      (chezmoi-template--activate-go-template-mode)
      (should (eq major-mode 'go-template-ts-mode)))))

(ert-deftest chezmoi-template-directory-uses-go-template-mode-without-host-extension ()
  (dolist (file '("/tmp/chezmoi/.chezmoitemplates/Brewfile"
                  "/tmp/chezmoi/.chezmoitemplates/script.tmpl"))
    (with-temp-buffer
      (setq buffer-file-name file)
      (setq-local chezmoi-mode t)
      (let ((go-template-calls 0)
            (polymode-calls 0))
        (cl-letf (((symbol-function 'go-template-ts-mode)
                   (lambda () (cl-incf go-template-calls)))
                  ((symbol-function 'poly-any-go-template-mode)
                   (lambda () (cl-incf polymode-calls))))
          (chezmoi-template--activate-go-template-mode))
        (should (= go-template-calls 1))
        (should (= polymode-calls 0))))))

(ert-deftest chezmoi-template-directory-uses-host-extension-for-polymode ()
  (dolist (case '(("/tmp/chezmoi/.chezmoitemplates/script.sh"
                   . "/tmp/chezmoi/.chezmoitemplates/script.sh.tmpl")
                  ("/tmp/chezmoi/.chezmoitemplates/script.sh.tmpl"
                   . "/tmp/chezmoi/.chezmoitemplates/script.sh.tmpl")))
    (with-temp-buffer
      (setq buffer-file-name (car case))
      (setq-local chezmoi-mode t)
      (let (activated-file)
        (cl-letf (((symbol-function 'poly-any-go-template-mode)
                   (lambda () (setq activated-file buffer-file-name))))
          (chezmoi-template--activate-go-template-mode))
        (should (equal activated-file (cdr case)))))))

(ert-deftest chezmoi-template-uses-treesit-expression-spans ()
  (skip-unless (treesit-ready-p 'gotmpl))
  (with-temp-buffer
    (insert "{{ .chezmoi.os }}\n")
    (go-template-ts-mode)
    (let ((spans (chezmoi-template--treesit-expression-spans)))
      (should (= (length spans) 1))
      (should (equal (buffer-substring-no-properties
                      (caar spans) (cdar spans))
                     "{{ .chezmoi.os }}")))))

(ert-deftest chezmoi-template-finds-selector-inside-control-action ()
  (skip-unless (treesit-ready-p 'gotmpl))
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

(ert-deftest chezmoi-capf-completes-the-final-selector-segment ()
  (skip-unless (treesit-ready-p 'gotmpl))
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

(ert-deftest chezmoi-template-uses-treesit-in-polymode ()
  (skip-unless (treesit-ready-p 'gotmpl))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/config.sh.tmpl")
    (insert "echo {{ .chezmoi.os }}\n")
    (poly-any-go-template-mode)
    (let (expressions)
      (cl-letf (((symbol-function 'chezmoi-template-execute)
                 (lambda (_) "darwin")))
        (chezmoi-template--funcall-over-matches
         (lambda (start end value buffer)
           (push (list (with-current-buffer buffer
                         (buffer-substring-no-properties start end))
                       value)
                 expressions))
         (current-buffer)))
      (should (equal expressions '(("{{ .chezmoi.os }}" "darwin")))))))

(ert-deftest chezmoi-does-not-activate-template-polymode-for-nontemplate ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh")
    (let ((chezmoi-mode t)
          (activated nil))
      (cl-letf (((symbol-function 'poly-any-go-template-mode)
                 (lambda () (setq activated t))))
        (chezmoi-template--activate-go-template-mode))
      (should-not activated))))

(provide 'chezmoi-test)
;;; chezmoi-test.el ends here
