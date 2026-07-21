;;; chezmoi-mode.el --- Interact with chezmoi from Emacs -*- lexical-binding: t -*-

;; Author: Harrison Pielke-Lombardo
;; Maintainer: Harrison Pielke-Lombardo
;; Version: 1.4.10
;; Package-Requires: ((emacs "29.1"))
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

;; Chezmoi is a dotfile management system that uses a source-target state
;; architecture.  This package provides convenience functions for maintaining
;; synchronization between the source and target states when making changes to
;; your dotfiles through Emacs.  It provides alternatives to `find-file' and
;; `save-buffer' for source state files which maintain synchronization to the
;; target state.  It also provides diff/ediff tools for resolving when dotfiles
;; get out of sync.  Dired and magit integration is also provided.

;;; Code:
(require 'chezmoi-core)
(require 'chezmoi-template)
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar chezmoi-mode nil)

(declare-function chezmoi-template-buffer-display "chezmoi-template" (&optional display-p start buffer-or-name))
(declare-function chezmoi-template-buffer-p "chezmoi-template" (&optional buffer-or-name))
(declare-function chezmoi-template-schedule-buffer-display "chezmoi-template" (&optional parser-found-p))
(declare-function chezmoi-template-set-completion "chezmoi-template" (enabled &optional buffer-or-name))
(declare-function chezmoi-template-source-file-p "chezmoi-core" (file))

(defmacro chezmoi--locally (&rest body)
  "Ensure BODY is run with a local `default-directory'."
  `(let ((default-directory (if (file-remote-p default-directory) (expand-file-name "~") default-directory)))
     ,@body))

(defun chezmoi--dispatch (args)
  "Run chezmoi with argument list ARGS and return output lines.
Return nil when the command exits unsuccessfully or reports an error."
  (let ((b (get-buffer-create "*chezmoi*")))
    (with-current-buffer b
      (erase-buffer)
      (let ((status (chezmoi--locally
                     (apply #'call-process chezmoi-command nil b nil args))))
        (let ((result (split-string (string-trim (buffer-string)) "\n")))
          (unless (or (not (zerop status))
                      (cl-some (lambda (line)
                                 (string-match-p chezmoi-command-error-regex line))
                               result))
            result))))))

(defun chezmoi--display-command-output (buffer-name args &optional json-p)
  "Run Chezmoi with ARGS and display its output in BUFFER-NAME.
Pretty-print the output first when JSON-P is non-nil."
  (let ((buffer (get-buffer-create buffer-name))
        status)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq status
              (chezmoi--locally
               (apply #'call-process chezmoi-command nil buffer nil args)))
        (goto-char (point-min))
        (when (and json-p (not (eobp)))
          (condition-case nil
              (json-pretty-print-buffer)
            (json-error nil)))
        (special-mode)))
    (display-buffer buffer)
    (unless (zerop status)
      (user-error "Chezmoi command failed: %s" (string-join args " ")))
    buffer))

;;;###autoload
(defun chezmoi-status ()
  "Display the status of managed files."
  (interactive)
  (chezmoi--display-command-output "*chezmoi-status*" '("status")))

;;;###autoload
(defun chezmoi-show-data ()
  "Display Chezmoi template data as formatted JSON."
  (interactive)
  (chezmoi--display-command-output "*chezmoi-data*" '("data") t))

;;;###autoload
(defun chezmoi-show-config ()
  "Display the effective Chezmoi configuration as formatted JSON."
  (interactive)
  (chezmoi--display-command-output
   "*chezmoi-config*" '("dump-config") t))

;;;###autoload
(defun chezmoi-doctor ()
  "Run `chezmoi doctor' and display its report."
  (interactive)
  (chezmoi--display-command-output "*chezmoi-doctor*" '("doctor")))

;;;###autoload
(defun chezmoi-open-source-directory ()
  "Open the Chezmoi source directory in Dired."
  (interactive)
  (if chezmoi-root
      (dired chezmoi-root)
    (user-error "Chezmoi source directory is unavailable")))

(defun chezmoi-managed ()
  "List all files and directories managed by chezmoi."
  (thread-last '("managed" "-x" "externals,scripts" "-p" "absolute")
	       chezmoi--dispatch
	       (cl-map 'list #'abbreviate-file-name)))

(defun chezmoi-managed-files ()
  "List only files managed by chezmoi."
  (thread-last (chezmoi-managed)
	       (cl-remove-if #'file-directory-p)))

(defun chezmoi--open-source-file (source-file &optional mode-file)
  "Visit SOURCE-FILE, infer its mode from MODE-FILE, and enable Chezmoi.
Return the visited buffer.  When MODE-FILE is nil, keep the mode selected from
SOURCE-FILE itself."
  (let ((chezmoi-auto-enable-mode nil))
    (find-file source-file))
  (when mode-file
    (let ((buffer-file-name mode-file))
      (set-auto-mode t)))
  (chezmoi-mode 1)
  (current-buffer))

;;;###autoload
(defun chezmoi-find-scripts (script)
  "Edit a source SCRIPT managed by chezmoi."
  (interactive
   (list (chezmoi--completing-read
          "Select a script to edit: "
          (thread-last
            '("managed" "-i" "scripts" "-p" "source-absolute")
            chezmoi--dispatch
            (cl-map 'list #'abbreviate-file-name))
          'project-file)))
  (chezmoi--open-source-file script))

(defun chezmoi-target-file-p (file)
  "Return non-nil if FILE is in the target state."
  (thread-last (chezmoi-managed-files)
	       (cl-mapcar #'expand-file-name)
	       (member (expand-file-name file))))

(defun chezmoi-source-file-p (file)
  "Return non-nil if `FILE' is in the source state."
  (and file chezmoi-root
       (file-in-directory-p file chezmoi-root)))

(defun chezmoi-encrypted-p (file)
  "Return non-nil if FILE is encrypted in the source state."
  (or (string-match "encrypted_" file)
      (string-match "encrypted_" (or (chezmoi-source-file file) ""))))

(defun chezmoi-template-file-p (file)
  "Return non-nil if FILE is a Chezmoi template file.

Does not check if the file is managed by chezmoi."
  (when-let ((source-file (if (chezmoi-source-file-p file)
                              file
                            (chezmoi-source-file file))))
    (chezmoi-template-source-file-p source-file)))

;;;###autoload
(defun chezmoi-diff (arg)
  "View output of =chezmoi diff= in a diff-buffer.
If ARG is non-nil, switch to the diff-buffer."
  (interactive "i")
  (let ((b (get-buffer-create "*chezmoi-diff*")))
    (with-current-buffer b
      (erase-buffer)
      (chezmoi--locally
       (call-process chezmoi-command nil b nil "diff" "--use-builtin-diff")))
    (unless arg
      (switch-to-buffer b)
      (diff-mode)
      (whitespace-mode 0))
    b))

(defvar chezmoi--merge-procs nil "List of chezmoi merge processes.")

;;;###autoload
(defun chezmoi-merge (file)
  "Run chezmoi merge on FILE.
Requires chezmoi to be configured with an external mergetool such as Emacs."
  (interactive
   (list (chezmoi--completing-read "Select a dotfile to merge: "
                   (chezmoi-changed-files)
                   'project-file)))
  (when (file-exists-p file)
    (push (start-process "chezmoi-merge" nil chezmoi-command "merge" file)
          chezmoi--merge-procs)))

;;;###autoload
(defun chezmoi-merge-all ()
  "Call `chezmoi merge-all'."
  (interactive)
  (push (start-process "chezmoi-merge-all" nil chezmoi-command "merge-all")
        chezmoi--merge-procs))

(defun chezmoi-merge-quit ()
  "Help, I ran chezmoi merge without reading the documentation!"
  (interactive)
  (dolist (i chezmoi--merge-procs)
    (kill-process i))
  (setq chezmoi--merge-procs nil))

(defun chezmoi-changed-files ()
  "Use chezmoi status to return the files that have changed."
  (let ((files '()))
    (with-temp-buffer

    (call-process chezmoi-command nil (current-buffer) nil "status")
    (while (re-search-backward "^[[:space:]|ADMR][ADMR] \\(.*\\)" nil t)
              (push (concat "~/" (match-string 1)) files))
      files)))

(defun chezmoi-changed-p (file)
  "Return non-nil of FILE has changed."
  (member (if (chezmoi-target-file-p file)
	      (chezmoi-target-file file)
	    file)
	  (chezmoi-changed-files)))

(defun chezmoi--write-after-save ()
  "Write the current source file when its destination should be updated."
  (when (or chezmoi-mode-overwrite-destination
            (chezmoi-changed-p buffer-file-name))
    (chezmoi-write)))

(defun chezmoi-version ()
  "Get version number of chezmoi."
  (interactive)
  (let* ((s (cl-first (chezmoi--dispatch '("--version"))))
	 (dev-re "\\(version \\(dev\\)\\)")
	 (v-re " \\(v\\(\\([0-9]+\\.\\)?\\([0-9]+\\.\\)?\\(\\*\\|[0-9]+\\)\\)\\)")
	 (re (concat dev-re "\\|" v-re))
         (version (when (and s (string-match re s))
                    (or (match-string 4 s)
	                (match-string 2 s)))))
    (when (called-interactively-p 'interactive)
      (if version
          (message "Chezmoi %s" version)
        (user-error "Unable to determine Chezmoi version")))
    version))

(defun chezmoi-get-data ()
  "Return chezmoi data."
  (json-parse-string (apply #'concat (chezmoi--dispatch '("data")))))

(defun chezmoi-get-config ()
  "Return the effective Chezmoi configuration."
  (let ((v (chezmoi-version)))
    (when (or (and v (string-match-p "^[0-9]" v) (version<= "2.27.0" v)) (string= "dev" v))
      (let ((config-string (apply #'concat (chezmoi--dispatch '("dump-config")))))
	(json-parse-string config-string
			   :array-type 'list
			   :null-object nil)))))

(defun chezmoi--manual-target-file (source-file)
  "Return the target file corresponding to SOURCE-FILE."
  (let* ((to-find (chezmoi--unchezmoi-source-file-name source-file))
	 (potential-targets (cl-remove-if-not (lambda (f)
						(let* ((dir (replace-regexp-in-string "~" "~/.local/share/chezmoi" (file-name-directory f)))
						       (base (file-name-base f))
						       (ext (file-name-extension f))
						       (corrected-f (concat dir
									    "/"
									    (if ext
										(concat (file-name-sans-extension base) "." ext)
									      base)))
						       (trying (expand-file-name corrected-f)))
						  (string= trying to-find)))
					      (chezmoi-managed-files))))
    (cond ((zerop (length potential-targets)) (progn
						(message "No target found")
						nil))
	  ((not (= 1 (length potential-targets)))
	   (progn
	     (message "Multiple targets found: %s. Using first" potential-targets)
	     (cl-first potential-targets)))
	  (t (cl-first potential-targets)))))

(make-obsolete-variable 'chezmoi--manual-target-file 'chezmoi-target-file "0.0.1")

(defun chezmoi-target-file (file)
  "Return the target file corresponding to FILE."
  (unless (chezmoi-target-file-p file)
    (let ((v (chezmoi-version)))
      (if (or (and v (string-match-p "^[0-9]" v) (version<= "2.12.0" v)) (string= "dev" v))
	  (cl-first (chezmoi--dispatch (list "target-path" file)))
	(chezmoi--manual-target-file file)))))

(defun chezmoi-source-file (file)
  "Return the source file corresponding to FILE."
  (when (chezmoi-target-file-p file)
    (cl-first (chezmoi--dispatch (list "source-path" file)))))

;;;###autoload
(defun chezmoi-write (&optional file arg)
  "Sync FILE.  How it syncs depends if FILE is in source or target.
If FILE is in source state, run =chezmoi apply= on the target to overwrite it.
With prefix ARG, pass =--force= to =chezmoi apply=.

If FILE is in target state, copy it to the source buffer without saving.
With prefix ARG, save the source buffer."
  (interactive (list (buffer-file-name)
		     current-prefix-arg))
  (let ((file (if file file (buffer-file-name))))
    (if (chezmoi-target-file-p file)
	;; File is in target state
	(let* ((target-file file)
	       (source-file (chezmoi-source-file target-file)))
	  (with-current-buffer (find-file-noselect source-file)
	    (replace-buffer-contents (find-file-noselect target-file))
	    (if arg
		(progn
		  (save-buffer)
		  (message "Wrote source: %s" source-file))
	      (message "Wrote source (unsaved): %s" source-file))
	    source-file))

      ;; File is in source state
      (let* ((source-file file)
             (target-file (chezmoi-target-file source-file))
             (args (append (list "apply" target-file)
			       (when arg (list "--force")))))
	    (if (chezmoi--dispatch args)
	    (progn
              (message "Wrote target: %s" target-file)
              target-file)
          (progn
            (message "Failed to write %s. Use chezmoi-write with prefix arg to resolve with chezmoi."
                     target-file)
            nil))))))

(defun chezmoi--completing-read (prompt choices category)
  "Completing read with meta data.
PROMPT, CHOICES, and CATEGORY are passed to `complete-with-action'."
  (completing-read prompt
		   (lambda (string predicate action)
		     (if (eq action 'metadata)
			 `(metadata (category . ,category))
		       (complete-with-action action choices string predicate)))
		   nil t))

;;;###autoload
(defun chezmoi-find (file)
  "Edit a source FILE managed by chezmoi.
If the target file has the same state as the source file,add a hook to
`save-buffer' that applies the source state to the target state.  This way, when
the buffer editing the source state is saved the target state is kept in sync.
Note: Does not run =chezmoi edit=."
  (interactive
   (list (chezmoi--completing-read "Select a dotfile to edit: "
				   (chezmoi-managed-files)
				   'project-file)))
  (let ((source-file (chezmoi-source-file file)))
    (when source-file
      (let ((target-file (expand-file-name file)))
        (chezmoi--open-source-file source-file target-file)
        (message "%s" target-file)
        source-file))))

;;;###autoload
(defun chezmoi-sync-files (files &optional arg)
  "Iteratively select file from FILES to sync.
Interactively select whether to sync the source state or the target state.
Prefix ARG is passed to `chezmoi-write'."
  (interactive
   (list (let ((choice (completing-read "Source or target?"
					'("Source" "Target")))
	       (files (chezmoi-changed-files)))
	   (if (string-equal "Source" choice)
	       (cl-mapcar #'chezmoi-source-file files)
	     files))
	 current-prefix-arg))
  (let (file)
    (while (and (setq file (chezmoi--completing-read "Select file to sync. (C-g to stop): "
						     files
						     'project-file))
		(chezmoi-write file arg))
      (setq files (remove file files)))))

;;;###autoload
(defun chezmoi-open-other (file)
  "Open buffer's target FILE."
  (interactive (list (buffer-file-name)))
  (if (chezmoi-target-file-p file)
      (chezmoi-find file)
    (find-file (chezmoi-target-file file))))

;;;###autoload
(define-minor-mode chezmoi-mode
  "Chezmoi mode for source files."
  :group 'chezmoi-mode-settings
  :lighter " Chezmoi"
  (defvar chezmoi-mode-overwrite-destination) ; silence
  (if chezmoi-mode
      (let ((template-p
             (and buffer-file-name
                  (chezmoi-template-source-file-p buffer-file-name))))
        (when (and template-p
                   (not (bound-and-true-p polymode-mode)))
          (run-hooks 'chezmoi-template-mode-hook)
          ;; A hook may select a major mode, which resets minor modes.
          (setq-local chezmoi-mode t))
        (add-hook 'after-save-hook #'chezmoi--write-after-save 0 t)
        (when (and template-p (chezmoi-template-set-completion t))
          (when chezmoi-template-display-p
            (chezmoi-template-schedule-buffer-display t))))
    (progn
      (chezmoi-template-buffer-display nil)
      (chezmoi-template-set-completion nil)
      (remove-hook 'after-save-hook #'chezmoi--write-after-save t))))

(provide 'chezmoi-mode)

;;; chezmoi-mode.el ends here
