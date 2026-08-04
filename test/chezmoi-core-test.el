;;; chezmoi-core-test.el --- Core tests for chezmoi -*- lexical-binding: t; no-native-compile: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'chezmoi-mode)

(defconst chezmoi-test--loaded-transient-p
  (featurep 'transient))

(defconst chezmoi-test--loaded-integration-features
  (mapcar (lambda (feature)
            (cons feature (featurep feature)))
          '(dired ediff magit
            chezmoi-dired chezmoi-ediff chezmoi-magit)))

(defconst chezmoi-test--loaded-go-template-ts-mode-p
  (featurep 'go-template-ts-mode))

(defconst chezmoi-test--loaded-poly-any-go-template-p
  (featurep 'poly-any-go-template))

(ert-deftest chezmoi-mode-provides-renamed-feature ()
  (should (featurep 'chezmoi-mode))
  (should-not (featurep 'chezmoi)))

(ert-deftest chezmoi-does-not-load-poly-any-go-template ()
  (should-not chezmoi-test--loaded-poly-any-go-template-p))

(ert-deftest chezmoi-does-not-load-go-template-ts-mode ()
  (should-not chezmoi-test--loaded-go-template-ts-mode-p))

(ert-deftest chezmoi-does-not-load-transient ()
  (should-not chezmoi-test--loaded-transient-p))

(ert-deftest chezmoi-does-not-load-integration-libraries ()
  (dolist (entry chezmoi-test--loaded-integration-features)
    (should-not (cdr entry))))

(ert-deftest chezmoi-special-source-find-commands-are-commands ()
  (dolist (command '(chezmoi-find-data
                     chezmoi-find-externals
                     chezmoi-find-scripts
                     chezmoi-find-templates
                     chezmoi-find-special-file))
    (should (commandp command))))

(ert-deftest chezmoi-find-scripts-omits-special-directory-from-candidates ()
  (let* ((root (make-temp-file "chezmoi-source" t))
         (chezmoi-root (file-name-as-directory root))
         (script (expand-file-name
                  ".chezmoiscripts/run_once_setup.sh.tmpl" root))
         completion-candidates
         opened-file)
    (unwind-protect
        (progn
          (make-directory (file-name-directory script) t)
          (with-temp-file script)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _)
                       (setq completion-candidates
                             (all-completions "" collection))
                       "run_once_setup.sh.tmpl"))
                    ((symbol-function 'chezmoi--open-source-file)
                     (lambda (file &optional _)
                       (setq opened-file file))))
            (call-interactively #'chezmoi-find-scripts)
            (should (equal completion-candidates
                           '("run_once_setup.sh.tmpl")))
            (should (equal opened-file script))))
      (delete-directory root t))))

(ert-deftest chezmoi-special-directory-files-separates-directory-types ()
  (let* ((root (make-temp-file "chezmoi-source" t))
         (chezmoi-root (file-name-as-directory root))
         (relative-files
          '(".chezmoidata/main.toml"
            ".chezmoiexternals/common.toml.tmpl"
            ".chezmoiscripts/run_once_setup.sh"
            ".chezmoitemplates/shared"
            "dot_config/.chezmoidata/nested.yaml"))
         (excluded-files
          '("dot_config/config.el"
            ".git/.chezmoidata/ignored.yaml")))
    (unwind-protect
        (progn
          (dolist (relative (append relative-files excluded-files))
            (let ((file (expand-file-name relative root)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file)))
          (dolist (case '((".chezmoidata"
                           ".chezmoidata/main.toml"
                           "dot_config/.chezmoidata/nested.yaml")
                          (".chezmoiexternals"
                           ".chezmoiexternals/common.toml.tmpl")
                          (".chezmoiscripts"
                           ".chezmoiscripts/run_once_setup.sh")
                          (".chezmoitemplates"
                           ".chezmoitemplates/shared")))
            (should
             (equal
              (sort (mapcar (lambda (file)
                              (file-relative-name file root))
                            (chezmoi-special-directory-files (car case)))
                    #'string<)
              (sort (copy-sequence (cdr case)) #'string<)))))
      (delete-directory root t))))

(ert-deftest chezmoi-special-directory-display-name-omits-matching-component ()
  (let ((root "/tmp/chezmoi/"))
    (should
     (equal
      (chezmoi--source-file-display-name
       "/tmp/chezmoi/.chezmoidata/packages.toml"
       root ".chezmoidata")
      "packages.toml"))
    (should
     (equal
      (chezmoi--source-file-display-name
       "/tmp/chezmoi/dot_config/.chezmoidata/packages.toml"
       root ".chezmoidata")
      "dot_config/packages.toml"))))

(ert-deftest chezmoi-special-files-honors-chezmoiroot ()
  (let* ((source-directory (make-temp-file "chezmoi-source" t))
         (source-root (expand-file-name "home" source-directory))
         (chezmoi-root (file-name-as-directory source-root))
         (relative-files
          '(".chezmoiroot"
            ".chezmoiversion"
            "home/.chezmoi.toml.tmpl"
            "home/.chezmoiignore.tmpl"
            "home/dot_config/.chezmoidata.yaml"
            "home/dot_config/.chezmoiexternal.toml.tmpl"))
         (excluded-files
          '("home/.chezmoidata.toml.tmpl"
            "home/.chezmoiignore.local"
            "home/dot_config/config.el")))
    (unwind-protect
        (progn
          (dolist (relative (append relative-files excluded-files))
            (let ((file (expand-file-name relative source-directory)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file)))
          (should (file-equal-p (chezmoi--source-directory)
                                source-directory))
          (should
           (equal
            (sort (mapcar (lambda (file)
                            (file-relative-name file source-directory))
                          (chezmoi-special-files))
                  #'string<)
            (sort (copy-sequence relative-files) #'string<))))
      (delete-directory source-directory t))))

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

(provide 'chezmoi-core-test)
;;; chezmoi-core-test.el ends here
