;;; chezmoi-test.el --- Tests for chezmoi -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi)

(ert-deftest chezmoi-template-file-p-requires-tmpl-suffix ()
  (let ((chezmoi-root "/tmp/chezmoi/"))
    (should (chezmoi-template-file-p "/tmp/chezmoi/run.sh.tmpl"))
    (should-not (chezmoi-template-file-p "/tmp/chezmoi/run.sh.tmpl.bak"))))

(ert-deftest chezmoi-activates-template-polymode-for-source-buffer ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/chezmoi/run.sh.tmpl")
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
