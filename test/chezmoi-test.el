;;; chezmoi-test.el --- Tests for chezmoi -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi)

(ert-deftest chezmoi-find-scripts-is-command ()
  (should (commandp #'chezmoi-find-scripts)))

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
        (chezmoi-mode 1))
      (should activated))))

(ert-deftest chezmoi-template-file-p-recognizes-template-sources ()
  (let ((chezmoi-root "/tmp/chezmoi/"))
    (should (chezmoi-template-file-p "/tmp/chezmoi/run.sh.tmpl"))
    (should (chezmoi-template-file-p "/tmp/chezmoi/modify_dot_config"))
    (should-not (chezmoi-template-file-p "/tmp/chezmoi/run.sh.tmpl.bak"))))

(ert-deftest chezmoi-activates-template-polymode-for-source-buffer ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/modify_dot_config")
    (let ((chezmoi-root "/tmp/chezmoi/")
          (chezmoi-mode t)
          (activated nil))
      (cl-letf (((symbol-function 'poly-any-go-template-mode)
                 (lambda () (setq activated t))))
        (chezmoi-template--activate-go-template-mode))
      (should activated))))

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
