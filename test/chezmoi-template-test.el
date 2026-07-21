;;; chezmoi-template-test.el --- Template tests for chezmoi -*- lexical-binding: t; no-native-compile: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi-mode)

(when (getenv "CHEZMOI_TEST_INTEGRATION")
  (require 'go-template-ts-mode nil t))

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

(ert-deftest chezmoi-template-display-is-enabled-by-default ()
  (should (default-value 'chezmoi-template-display-p)))

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

(provide 'chezmoi-template-test)
;;; chezmoi-template-test.el ends here
