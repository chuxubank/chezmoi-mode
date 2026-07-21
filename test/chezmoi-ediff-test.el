;;; chezmoi-ediff-test.el --- Ediff tests for chezmoi -*- lexical-binding: t; no-native-compile: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi-ediff)

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

(provide 'chezmoi-ediff-test)
;;; chezmoi-ediff-test.el ends here
