;;; chezmoi-transient.el --- Transient menu for chezmoi-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Misaka

;; Author: Harrison Pielke-Lombardo
;; Maintainer: Harrison Pielke-Lombardo
;; Homepage: https://github.com/chuxubank/chezmoi-mode
;; Keywords: convenience, vc

;; This file is not part of GNU Emacs.

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

;; Provides a Transient menu for Chezmoi commands and bundled integrations.

;;; Code:

(require 'chezmoi-mode)
(require 'transient)

(autoload 'chezmoi-dired-add-marked-files "chezmoi-dired" nil t)
(autoload 'chezmoi-ediff "chezmoi-ediff" nil t)
(autoload 'chezmoi-ediff-merge "chezmoi-ediff" nil t)
(autoload 'chezmoi-magit-status "chezmoi-magit" nil t)

(defun chezmoi-transient--current-file-p ()
  "Return non-nil when the current buffer visits a file."
  buffer-file-name)

(defun chezmoi-transient--base-buffer ()
  "Return the base buffer for the current Transient context."
  (or (buffer-base-buffer) (current-buffer)))

(defun chezmoi-transient--mode-description ()
  "Return a state-aware description for `chezmoi-mode'."
  (with-current-buffer (chezmoi-transient--base-buffer)
    (if chezmoi-mode "Disable Chezmoi mode" "Enable Chezmoi mode")))

(defun chezmoi-transient--display-description ()
  "Return a state-aware description for template display."
  (with-current-buffer (chezmoi-transient--base-buffer)
    (if (bound-and-true-p chezmoi-template--buffer-displayed-p)
        "Hide template values"
      "Display template values")))

(defun chezmoi-transient--template-buffer-p ()
  "Return non-nil when template display is available in this buffer."
  (chezmoi-template-buffer-p (chezmoi-transient--base-buffer)))

(transient-define-suffix chezmoi-transient-write ()
  "Write the current file, honoring the transient force argument."
  (interactive)
  (chezmoi-write buffer-file-name
                 (member "--force" (transient-args 'chezmoi-transient))))

(transient-define-suffix chezmoi-transient-sync-files ()
  "Sync changed files, honoring the transient force argument."
  (interactive)
  (let ((current-prefix-arg
         (and (member "--force" (transient-args 'chezmoi-transient))
              '(4))))
    (call-interactively #'chezmoi-sync-files)))

(transient-define-suffix chezmoi-transient-toggle-mode ()
  "Toggle `chezmoi-mode' in the current base buffer."
  (interactive)
  (with-current-buffer (chezmoi-transient--base-buffer)
    (call-interactively #'chezmoi-mode)))

;;;###autoload
(transient-define-prefix chezmoi-transient ()
  "Manage Chezmoi source and target files."
  [["Files"
    ("f" "Find managed file" chezmoi-find)
    ("F" "Find script" chezmoi-find-scripts)
    ("o" "Open source/target" chezmoi-open-other
     :inapt-if-not chezmoi-transient--current-file-p)
    ("r" "Open source directory" chezmoi-open-source-directory)]
   ["Changes"
    ("-f" "Force apply/save" "--force")
    ("w" "Write current file" chezmoi-transient-write
     :inapt-if-not chezmoi-transient--current-file-p)
    ("s" "Sync changed files" chezmoi-transient-sync-files)
    ("d" "Show diff" chezmoi-diff)
    ("S" "Show status" chezmoi-status)]
   ["Resolve"
    ("e" "Ediff source/target" chezmoi-ediff)
    ("E" "Ediff with ancestor" chezmoi-ediff-merge)
    ("m" "Run merge" chezmoi-merge)
    ("M" "Run merge-all" chezmoi-merge-all)
    ("q" "Stop merge processes" chezmoi-merge-quit)]]
  [["Inspect"
    ("D" "Show template data" chezmoi-show-data)
    ("C" "Show configuration" chezmoi-show-config)
    ("x" "Run doctor" chezmoi-doctor)
    ("v" "Show version" chezmoi-version)]
   ["Current buffer"
    ("t" "Toggle template values" chezmoi-template-buffer-display
     :description chezmoi-transient--display-description
     :inapt-if-not chezmoi-transient--template-buffer-p)
    ("c" "Toggle Chezmoi mode" chezmoi-transient-toggle-mode
     :description chezmoi-transient--mode-description
     :inapt-if-not chezmoi-transient--current-file-p)]
   ["Integrations"
    ("g" "Magit source repository" chezmoi-magit-status)
    ("a" "Add Dired marked files" chezmoi-dired-add-marked-files
     :if-mode dired-mode)]])

(provide 'chezmoi-transient)
;;; chezmoi-transient.el ends here
