;;; chezmoi-core.el --- A package for interacting with chezmoi -*- lexical-binding: t -*-

;; Author: Harrison Pielke-Lombardo
;; Maintainer: Harrison Pielke-Lombardo
;; Version: 1.4.0
;; Package-Requires: ((emacs "29.1"))
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

;; Chezmoi is a dotfile management system that uses a source-target state
;; architecture.  This package provides convenience functions for maintaining
;; synchronization between the source and target states when making changes to
;; your dotfiles through Emacs.  It provides alternatives to `find-file' and
;; `save-buffer' for source state files which maintain synchronization to the
;; target state.  It also provides diff/ediff tools for resolving when dotfiles
;; get out of sync.  Dired and magit integration is also provided.

;;; Code:

(require 'subr-x)

(defgroup chezmoi nil
  "Customization group for `chezmoi-mode'."
  :group 'chezmoi)

(defvar chezmoi-mode nil)
(declare-function chezmoi-mode "chezmoi" ())

(defcustom chezmoi-command "chezmoi"
  "The location of the chezmoi command."
  :type '(string)
  :group 'chezmoi)

(defcustom chezmoi-use-template-source-mode-regex '(".*")
  "If any match, activates the target file major mode in template files."
  :group 'chezmoi
  :type '(repeat string))

(defcustom chezmoi-mode-overwrite-destination nil
  "Always attach a hook to write to the target file to chezmoi buffers.
If the target has been changed, it will be overwritten."
  :group 'chezmoi
  :type '(boolean))

(defun chezmoi--default-root ()
  "Return the configured chezmoi source directory, if available."
  (when-let ((command (executable-find chezmoi-command)))
    (with-temp-buffer
      (when (zerop (call-process command nil t nil "source-path"))
        (let ((path (string-trim (buffer-string))))
          (unless (string-empty-p path)
            (file-name-as-directory (expand-file-name path))))))))

(defcustom chezmoi-root (chezmoi--default-root)
  "The source directory for chezmoi.
When nil, Chezmoi is unavailable or has not reported a source directory."
  :group 'chezmoi
  :type '(choice (const :tag "Auto/unavailable" nil) directory))

(defvar chezmoi-command-error-regex "chezmoi:"
  "Regex for detecting if chezmoi has encountered an error.")

(defvar chezmoi-source-state-prefix-attrs
  '("after_"
    "before_"
    "create_"
    "dot_"
    "empty_"
    "encrypted_"
    "exact_"
    "executable_"
    "literal_"
    "modify_"
    "once_"
    "onchange_"
    "private_"
    "readonly_"
    "remove_"
    "run_"
    "symlink_")
  "Source state attribute prefixes.")

(defvar chezmoi-source-state-suffix-attrs
  '(".literal"
    ".tmpl")
  "Source state attribute suffixes.")

(defun chezmoi-template-source-file-p (file)
  "Return non-nil when FILE contains a Go template.
Chezmoi marks templates with a `.tmpl' suffix or a `modify_' prefix."
  (when file
    (let ((name (file-name-nondirectory file)))
      (or (string-suffix-p ".tmpl" name)
          (string-prefix-p "modify_" name)))))

(defun chezmoi--mode-from-path ()
  "Activate `chezmoi-mode' in source files based on their path."
  (when (and chezmoi-root
             buffer-file-name
             (file-in-directory-p buffer-file-name chezmoi-root))
    (unless chezmoi-mode (chezmoi-mode))))

(add-hook 'find-file-hook #'chezmoi--mode-from-path)

(provide 'chezmoi-core)

;;; chezmoi-core.el ends here
