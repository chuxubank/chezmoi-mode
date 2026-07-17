;;; chezmoi-ediff.el --- Ediff integration for chezmoi -*- lexical-binding: t -*-

;; Author: Harrison Pielke-Lombardo
;; Maintainer: Harrison Pielke-Lombardo
;; Version: 1.3.1
;; Package-Requires: ((emacs "29.1") (chezmoi "1.3.1"))
;; Homepage: https://github.com/chuxubank/chezmoi.el
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

(require 'chezmoi)
(require 'ediff)

(defcustom chezmoi-ediff-force-overwrite t
  "Whether to force file overwrite when ediff finishes with identical buffers."
  :type '(boolean)
  :group 'chezmoi)

(defcustom chezmoi-ediff-template-use-ediff3 t
  "If `chezmoi-ediff' between template files should .
This creates false diffs for every template element, but allows easily
changing the source template file."
  :type '(boolean)
  :group 'chezmoi)

(defvar-local chezmoi-ediff--source-file nil
  "Current ediff source-file.")

(defun chezmoi-ediff--ediff-get-region-contents (n buf-type ctrl-buf &optional start end)
  "An overriding fn for `ediff-get-region-contents'.
Converts and applies template diffs from the source-file.
N, BUF-TYPE, CTRL-BUF, START, and END are all passed to `ediff'."
  (ediff-with-current-buffer
      (ediff-with-current-buffer ctrl-buf (ediff-get-buffer buf-type))
    (if (string-equal chezmoi-ediff--source-file (buffer-file-name))
        (chezmoi-template-execute (buffer-substring-no-properties
                                   (or start (ediff-get-diff-posn buf-type 'beg n ctrl-buf))
                                   (or end (ediff-get-diff-posn buf-type 'end n ctrl-buf))))
      (buffer-substring
       (or start (ediff-get-diff-posn buf-type 'beg n ctrl-buf))
       (or end (ediff-get-diff-posn buf-type 'end n ctrl-buf))))))

(defun chezmoi-ediff--ediff-cleanup-hook ()
  (when chezmoi-ediff-force-overwrite
    (when-let (source-file (or (with-current-buffer ediff-buffer-A chezmoi-ediff--source-file)
			       (with-current-buffer ediff-buffer-B chezmoi-ediff--source-file)))
      (when (equal (with-current-buffer ediff-buffer-A (buffer-string))
		   (with-current-buffer ediff-buffer-B (buffer-string)))
	(chezmoi-write source-file t)))))

(defun chezmoi-ediff--ediff-quit-hook ()
  "Remove the temporary template-aware Ediff advice."
  (advice-remove 'ediff-get-region-contents
                 #'chezmoi-ediff--ediff-get-region-contents))

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
      (user-error "Error finding source and target files."))
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
  (let* ((source-file (chezmoi-find file)))
      (if (and chezmoi-ediff-template-use-ediff3
               (not (chezmoi-encrypted-p source-file))
               (chezmoi-template-file-p source-file))
          (progn (let ((temp (make-temp-file (file-name-nondirectory file))))
                   (with-temp-file temp
                     (insert (with-temp-buffer
                               (insert-file-contents source-file)
                               (chezmoi-template-execute (buffer-string)))))
                (ediff3 temp file source-file)))
      (advice-add 'ediff-get-region-contents :override #'chezmoi-ediff--ediff-get-region-contents)
      (setq chezmoi-ediff--source-file source-file)
      (ediff source-file file)
      ;; (ediff-merge-files-with-ancestor source-file file (chezmoi--get-ancestor source-file) nil file)
      (add-hook 'ediff-cleanup-hook #'chezmoi-ediff--ediff-cleanup-hook nil t)
      (add-hook 'ediff-quit-hook #'chezmoi-ediff--ediff-quit-hook nil t))))

(provide 'chezmoi-ediff)
;;; chezmoi-ediff.el ends here
