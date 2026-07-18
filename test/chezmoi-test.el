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

(ert-deftest chezmoi-transient-is-command ()
  (should (commandp #'chezmoi-transient)))

(ert-deftest chezmoi-mode-initializes-template-module ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh.tmpl")
    (let ((activated nil))
      (cl-letf (((symbol-function 'chezmoi-changed-p) (lambda (&rest _) nil))
                ((symbol-function 'chezmoi-template--activate-go-template-mode)
                 (lambda () (setq activated t)))
                ((symbol-function 'chezmoi-template-buffer-display)
                 (lambda (&rest _) nil)))
        (chezmoi-mode 1)
        (should (memq #'chezmoi-capf completion-at-point-functions))
        (chezmoi-mode -1)
        (should-not (memq #'chezmoi-capf completion-at-point-functions)))
      (should activated))))

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
