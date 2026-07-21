;;; chezmoi-ediff.el --- Ediff integration for chezmoi -*- lexical-binding: t -*-

;; Author: Harrison Pielke-Lombardo
;; Maintainer: Harrison Pielke-Lombardo
;; Version: 1.4.10
;; Package-Requires: ((emacs "29.1") (chezmoi-mode "1.4.10"))
;; Homepage: https://github.com/chuxubank/chezmoi-mode
;; Keywords: vc


;; This file is not part of GNU Emacs

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.


;;; Commentary:

;; Provides `ediff' integration for `chezmoi'.

;;; Code:

(require 'cl-lib)
(require 'chezmoi-mode)
(require 'ediff)

(defcustom chezmoi-ediff-force-overwrite t
  "Whether to force file overwrite when ediff finishes with identical buffers."
  :type '(boolean)
  :group 'chezmoi-mode-settings)

(defcustom chezmoi-ediff-template-use-ediff3 t
  "If `chezmoi-ediff' between template files should .
This creates false diffs for every template element, but allows easily
changing the source template file."
  :type '(boolean)
  :group 'chezmoi-mode-settings)

(defvar-local chezmoi-ediff--source-file nil
  "Source file associated with the current Ediff control buffer.")

(defvar-local chezmoi-ediff--template-source-file nil
  "Template source file associated with the current Ediff control buffer.")

(defvar-local chezmoi-ediff--rendered-temp-file nil
  "Rendered temporary file associated with the current Ediff control buffer.")

(defvar chezmoi-ediff--template-sessions nil
  "Live Ediff control buffers that compare a template source file.")

(defun chezmoi-ediff--same-file-p (file-a file-b)
  "Return non-nil when FILE-A and FILE-B name the same file."
  (and file-a file-b
       (string-equal (expand-file-name file-a)
                     (expand-file-name file-b))))

(defun chezmoi-ediff--ediff-get-region-contents
    (old-function n buf-type ctrl-buf &optional start end)
  "Call OLD-FUNCTION, rendering template source regions when appropriate.
N, BUF-TYPE, CTRL-BUF, START, and END are passed to
`ediff-get-region-contents'."
  (let* ((source-file
          (and (buffer-live-p ctrl-buf)
               (buffer-local-value
                'chezmoi-ediff--template-source-file ctrl-buf)))
         (variant-buffer
          (and source-file
               (with-current-buffer ctrl-buf
                 (ediff-get-buffer buf-type)))))
    (if (and (buffer-live-p variant-buffer)
             (chezmoi-ediff--same-file-p
              source-file (buffer-file-name variant-buffer)))
        (with-current-buffer variant-buffer
          (chezmoi-template-execute
           (buffer-substring-no-properties
            (or start (ediff-get-diff-posn buf-type 'beg n ctrl-buf))
            (or end (ediff-get-diff-posn buf-type 'end n ctrl-buf)))))
      (funcall old-function n buf-type ctrl-buf start end))))

(defun chezmoi-ediff--ensure-template-advice ()
  "Install the template-aware Ediff advice if necessary."
  (unless (advice-member-p #'chezmoi-ediff--ediff-get-region-contents
                           'ediff-get-region-contents)
    (advice-add 'ediff-get-region-contents :around
                #'chezmoi-ediff--ediff-get-region-contents)))

(defun chezmoi-ediff--prune-template-sessions ()
  "Prune dead template sessions and synchronize the Ediff advice."
  (setq chezmoi-ediff--template-sessions
        (cl-delete-if-not #'buffer-live-p
                          chezmoi-ediff--template-sessions))
  (if chezmoi-ediff--template-sessions
      (chezmoi-ediff--ensure-template-advice)
    (advice-remove 'ediff-get-region-contents
                   #'chezmoi-ediff--ediff-get-region-contents)))

(defun chezmoi-ediff--unregister-template-session ()
  "Unregister the current Ediff control buffer's template session."
  (setq chezmoi-ediff--template-sessions
        (delq (current-buffer) chezmoi-ediff--template-sessions))
  (setq-local chezmoi-ediff--source-file nil)
  (setq-local chezmoi-ediff--template-source-file nil)
  (remove-hook 'ediff-cleanup-hook
               #'chezmoi-ediff--ediff-cleanup-hook t)
  (remove-hook 'kill-buffer-hook
               #'chezmoi-ediff--unregister-template-session t)
  (chezmoi-ediff--prune-template-sessions))

(defun chezmoi-ediff--register-session (source-file template-p)
  "Register the current Ediff control buffer for SOURCE-FILE.
When TEMPLATE-P is non-nil, enable template-aware region handling."
  (setq-local chezmoi-ediff--source-file source-file)
  (setq-local chezmoi-ediff--template-source-file
              (and template-p source-file))
  (add-hook 'ediff-cleanup-hook #'chezmoi-ediff--ediff-cleanup-hook nil t)
  (add-hook 'kill-buffer-hook
            #'chezmoi-ediff--unregister-template-session nil t)
  (when template-p
    (cl-pushnew (current-buffer) chezmoi-ediff--template-sessions)
    (chezmoi-ediff--ensure-template-advice)))

(defun chezmoi-ediff--delete-rendered-temp-file ()
  "Delete the rendered temporary file registered in the current buffer."
  (when-let ((file chezmoi-ediff--rendered-temp-file))
    (setq-local chezmoi-ediff--rendered-temp-file nil)
    (when (file-exists-p file)
      (delete-file file)))
  (remove-hook 'ediff-cleanup-hook
               #'chezmoi-ediff--delete-rendered-temp-file t)
  (remove-hook 'kill-buffer-hook
               #'chezmoi-ediff--delete-rendered-temp-file t))

(defun chezmoi-ediff--register-rendered-temp-file (file)
  "Register rendered temporary FILE in the current Ediff control buffer."
  (setq-local chezmoi-ediff--rendered-temp-file file)
  (add-hook 'ediff-cleanup-hook
            #'chezmoi-ediff--delete-rendered-temp-file nil t)
  (add-hook 'kill-buffer-hook
            #'chezmoi-ediff--delete-rendered-temp-file nil t))

(defun chezmoi-ediff--ediff-cleanup-hook ()
  "Apply identical variants when requested and unregister the session."
  (unwind-protect
      (when (and chezmoi-ediff-force-overwrite
                 chezmoi-ediff--source-file
                 (buffer-live-p ediff-buffer-A)
                 (buffer-live-p ediff-buffer-B)
                 (equal (with-current-buffer ediff-buffer-A
                          (buffer-string))
		        (with-current-buffer ediff-buffer-B
                          (buffer-string))))
        (chezmoi-write chezmoi-ediff--source-file t))
    (chezmoi-ediff--unregister-template-session)))

(defun chezmoi--get-ancestor (source-file)
  "Create a temp file for SOURCE-FILE at git HEAD."
  (let* ((relative (file-relative-name source-file chezmoi-root))
         (rev (with-temp-buffer
                (let ((default-directory chezmoi-root))
                  (call-process "git" nil t nil "rev-parse" "--short" "HEAD"))
                (string-trim (buffer-string))))
         (temp-name (expand-file-name relative (expand-file-name rev temporary-file-directory))))
    (make-directory (file-name-directory temp-name) t)
    (with-temp-file temp-name
      (let ((default-directory chezmoi-root))
        (call-process "git" nil t nil "show" (concat rev ":" relative))))
    temp-name))

;;;###autoload
(defun chezmoi-ediff-merge (file)
  "Start an `ediff-merge-with-ancestor' session of `FILE'.
Merge source, target, and ancestor.

Note: Does not run =chezmoi merge=."
  (interactive (list (buffer-file-name)))
  (let* ((target (chezmoi-target-file-p file))
         (sourcef (if target
                    (chezmoi-source-file file)
                  file))
        (targetf (if target
                     file
                   (chezmoi-target-file file))))
    (unless (and sourcef targetf)
      (user-error "Error finding source and target files"))
    (ediff-merge-buffers-with-ancestor
     (if (chezmoi-template-file-p sourcef)
         (chezmoi-template--buffer sourcef)
       (find-file sourcef))
     (find-file-noselect targetf)
     (find-file-noselect (chezmoi--get-ancestor sourcef)))))

(defun chezmoi-template--buffer (template-file)
  "Execute template from `TEMPLATE-FILE' and insert into a new buffer.
Return the new buffer."
  (unless (chezmoi-template-file-p template-file)
    (error "File: %s is not a chezmoi template file" template-file))
  (let ((buf (get-buffer-create (make-temp-name template-file))))
    (with-temp-buffer
      (insert-file-contents template-file)
      (let ((output (chezmoi-template-execute (buffer-string))))
        (with-current-buffer buf
          (erase-buffer)
          (insert output))))
    buf))

;;;###autoload
(defun chezmoi-ediff (file)
  "Choose a FILE to merge with its source using `ediff'.
If the current file is in `chezmoi-mode', diff the current file.
Otherwise, or if used with a prefix arg, choose from all chezmoi
managed files.

Note: Does not run =chezmoi merge=."
  (interactive
   (list (if (and chezmoi-mode (not current-prefix-arg))
             (chezmoi-target-file (buffer-file-name))
           (chezmoi--completing-read "Select a dotfile to merge: "
				   (chezmoi-changed-files)
				   'project-file))))
  (let* ((source-file (chezmoi-find file))
         (template-p
          (and (not (chezmoi-encrypted-p source-file))
               (chezmoi-template-file-p source-file))))
    (if (and chezmoi-ediff-template-use-ediff3 template-p)
        (let ((temp (make-temp-file (file-name-nondirectory file)))
              control-buffer completed registered)
          (unwind-protect
              (progn
                (with-temp-file temp
                  (insert (with-temp-buffer
                            (insert-file-contents source-file)
                            (chezmoi-template-execute (buffer-string)))))
                (prog1
                    (ediff3
                     temp file source-file
                     (list
                      (lambda ()
                        (setq control-buffer (current-buffer))
                        (chezmoi-ediff--register-rendered-temp-file temp)
                        (setq registered t))))
                  (setq completed t)))
            (unless (and completed registered)
              (if (buffer-live-p control-buffer)
                  (with-current-buffer control-buffer
                    (chezmoi-ediff--delete-rendered-temp-file))
                (when (file-exists-p temp)
                  (delete-file temp))))))
      (let (control-buffer completed registered)
        (when template-p
          (chezmoi-ediff--ensure-template-advice))
        (unwind-protect
            (prog1
                (ediff
                 source-file file
                 (list
                  (lambda ()
                    (setq control-buffer (current-buffer))
                    (chezmoi-ediff--register-session source-file template-p)
                    (setq registered t))))
              (setq completed t))
          (unless (and completed registered)
            (if (buffer-live-p control-buffer)
                (with-current-buffer control-buffer
                  (chezmoi-ediff--unregister-template-session))
              (chezmoi-ediff--prune-template-sessions))))))))

(provide 'chezmoi-ediff)
;;; chezmoi-ediff.el ends here
