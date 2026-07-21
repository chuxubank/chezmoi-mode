;;; chezmoi-autoload-test.el --- Autoload tests for chezmoi-mode -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'loaddefs-gen)

(defvar chezmoi-auto-enable-mode)
(defvar chezmoi-mode)
(defvar chezmoi-root)

(defconst chezmoi-autoload-test--source-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Directory containing the chezmoi-mode sources under test.")

(ert-deftest chezmoi-autoload-enables-mode-for-direct-source-visits ()
  "Loading only generated autoloads should initialize path-based activation."
  (should-not (featurep 'chezmoi-core))
  (let* ((root (make-temp-file "chezmoi-autoload-root" t))
         (source-file (expand-file-name "dot_config" root))
         (autoload-file (make-temp-file "chezmoi-mode-autoloads" nil ".el"))
         (find-file-hook (remove #'chezmoi--mode-from-path find-file-hook))
         (chezmoi-root (file-name-as-directory root))
         (chezmoi-auto-enable-mode t)
         buffer)
    (unwind-protect
        (progn
          (loaddefs-generate chezmoi-autoload-test--source-directory
                             autoload-file nil nil nil t)
          (load autoload-file nil t)
          (should (memq #'chezmoi--mode-from-path find-file-hook))
          (with-temp-file source-file)
          (setq buffer (find-file-noselect source-file))
          (with-current-buffer buffer
            (should chezmoi-mode)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file autoload-file)
      (delete-directory root t))))

(provide 'chezmoi-autoload-test)
;;; chezmoi-autoload-test.el ends here
