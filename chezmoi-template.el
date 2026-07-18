;;; chezmoi-template.el --- Display chezmoi templates -*- lexical-binding: t -*-

;; Author: Harrison Pielke-Lombardo
;; Maintainer: Harrison Pielke-Lombardo
;; Version: 1.4.0
;; Package-Requires: ((emacs "29.1") (poly-any-go-template "0.1.0"))
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
(require 'chezmoi-core)
(require 'cl-lib)
(require 'go-template-ts-mode)
(require 'poly-any-go-template)

(declare-function chezmoi-template-source-file-p "chezmoi-core" (file))
(declare-function chezmoi-get-data "chezmoi" ())

(defun chezmoi-template--activate-go-template-mode ()
  "Use Go-template polymode for Chezmoi template source buffers.
The current major mode remains the host mode inferred from the target file.
This is called by `chezmoi-mode' before template display is initialized."
  (when (and (bound-and-true-p chezmoi-mode)
             buffer-file-name
             (chezmoi-template-source-file-p buffer-file-name)
             (not (bound-and-true-p polymode-mode)))
    (cond ((eq major-mode 'go-template-ts-mode))
          ((memq major-mode '(fundamental-mode text-mode))
           (go-template-ts-mode))
          (t
           (poly-any-go-template-mode)))
    (setq-local chezmoi-mode t)))

(defcustom chezmoi-template-display-p nil
  "Whether to display templates."
  :type '(boolean)
  :group 'chezmoi
  :local t)

(defcustom chezmoi-template-display-delay 0.2
  "Idle delay before refreshing displayed template values after a change."
  :type '(number)
  :group 'chezmoi)

(defvar-local chezmoi-template--buffer-displayed-p nil
  "Whether all templates are currently displayed in buffer.")

(defvar-local chezmoi-template--display-timer nil
  "Pending idle timer for refreshing displayed template values.")

(defvar chezmoi-template-key-regex "\\."
  "Regex for splitting keys.")

(defun chezmoi-template-execute (template)
  "Convert TEMPLATE using chezmoi and return its output."
  (with-temp-buffer
    (call-process chezmoi-command nil t nil "execute-template" template)
    (buffer-string)))

(defun chezmoi-template--selector-node-at-point ()
  "Return the Go template selector node at point, if any."
  (when (and (treesit-ready-p 'gotmpl)
             (treesit-parser-list))
    (let ((node (treesit-node-at (max (point-min) (1- (point))))))
      (while (and node
                  (not (equal (treesit-node-type node)
                              "selector_expression")))
        (setq node (treesit-node-parent node)))
      node)))

(defvar chezmoi-template--completion-properties
  (list :annotation-function (lambda (_) " Keyword")
        :company-kind (lambda (_) 'keyword)
        :exclusive 'no)
  "Extra properties returned by `chezmoi-capf'.")

(defun chezmoi-template--completion-candidates (selector)
  "Return completion candidates for SELECTOR from `chezmoi-get-data'."
  (let* ((keys (thread-last chezmoi-template-key-regex
                            (split-string selector)
                            butlast
                            (remove "")))
         (hashget (lambda (data key)
                    (when (hash-table-p data)
                      (gethash key data))))
         (data (cl-reduce hashget keys
                          :initial-value (chezmoi-get-data))))
    (cond ((hash-table-p data) (hash-table-keys data))
          ((stringp data) (list data))
          (t nil))))

(defun chezmoi-template--completion-bounds (node)
  "Return completion bounds for the final segment of selector NODE."
  (save-excursion
    (goto-char (min (point) (treesit-node-end node)))
    (skip-syntax-backward "w_" (treesit-node-start node))
    (cons (point) (treesit-node-end node))))

(defun chezmoi-capf ()
  "Complete the Chezmoi template selector at point."
  (when-let ((node (chezmoi-template--selector-node-at-point)))
    (let* ((bounds (chezmoi-template--completion-bounds node))
           (beg (car bounds))
           (end (cdr bounds))
           (selector (treesit-node-text node t))
           (candidates (chezmoi-template--completion-candidates selector)))
      `(,beg ,end
             ,(completion-table-dynamic (lambda (_) candidates))
             :category chezmoi-template
             ,@chezmoi-template--completion-properties))))

(defun chezmoi-template--treesit-expression-spans (&optional minimum maximum)
  "Return simple Go template expression spans in the current buffer.
Only direct selector expressions such as `{{ .foo }}' are returned."
  (when (and (treesit-ready-p 'gotmpl)
             (treesit-parser-list))
    (let ((children (treesit-node-children
                     (treesit-buffer-root-node 'gotmpl)))
           (minimum (or minimum (point-min)))
           (maximum (or maximum (point-max)))
           spans)
      (while (cddr children)
        (let* ((opening (car children))
               (node (cadr children))
               (closing (caddr children))
               (start (treesit-node-start opening))
               (end (treesit-node-end closing)))
          (when (and (member (treesit-node-type opening) '("{{" "{{-"))
                     (equal (treesit-node-type node) "selector_expression")
                     (member (treesit-node-type closing) '("}}" "-}}"))
                     (<= minimum start)
                     (<= end maximum))
            (push (cons start end) spans))
          (setq children (cdr children))))
      (nreverse spans))))

(defun chezmoi-template--put-display-value (start end value &optional object)
  "Display the VALUE from START to END in string or buffer OBJECT."
  (unless (string-match-p chezmoi-command-error-regex value)
    (put-text-property start end 'display value object)
    (put-text-property start end 'chezmoi t object)
    (font-lock-flush start end)
    (font-lock-ensure start end)))

(defun chezmoi-template--remove-display-value (start end &optional object)
  "Remove displayed template from START to END in OBJECT.
VALUE is ignored."
  (when (and start end)
    (let ((value (get-text-property start 'display object)))
      (remove-text-properties start end `(
                                          display ,value
                                          chezmoi t)
                              object)
      (font-lock-flush start end)
      (font-lock-ensure start end))))

(defun chezmoi-template--funcall-over-spans (f spans buffer-or-name)
  "Call F for SPANS in BUFFER-OR-NAME after executing each expression."
  (with-current-buffer buffer-or-name
    (dolist (span spans)
      (let* ((start (car span))
             (end (cdr span))
             (template (buffer-substring-no-properties start end))
             (value (chezmoi-template-execute template)))
        (funcall f start end value buffer-or-name)))))

(defun chezmoi-template--funcall-over-matches (f buffer-or-name)
  "Call F on each matching template in BUFFER-OR-NAME.
F is called with the start of the match, the end of the match,
the template value and BUFFER-OR-NAME."
  (with-current-buffer buffer-or-name
    (cond
     ((eq major-mode 'go-template-ts-mode)
      (chezmoi-template--funcall-over-spans
       f (chezmoi-template--treesit-expression-spans) buffer-or-name))
     ((bound-and-true-p polymode-mode)
      (let ((base-buffer (current-buffer)))
        (pm-map-over-spans
         (lambda (span)
           (when (eq major-mode 'go-template-ts-mode)
             (dolist (expression
                      (chezmoi-template--treesit-expression-spans
                       (nth 1 span) (nth 2 span)))
               (with-current-buffer base-buffer
                 (let* ((start (car expression))
                        (end (cdr expression))
                        (template (buffer-substring-no-properties start end))
                        (value (chezmoi-template-execute template)))
                   (funcall f start end value base-buffer))))))))))))

(defun chezmoi-template--funcall-over-display-properties (f start buffer-or-name)
  "Call F on each occurrence with display property in BUFFER-OR-NAME.
F is called with the start of the occurrence, the end of the occurrence,
the display property value, and BUFFER-OR-NAME.
When START is non-nil, find only the region around START."
  (with-current-buffer buffer-or-name
    (let ((end (or start 1))
          (buf (current-buffer)))
      (if start
          (let* ((start (or (previous-single-property-change
                             end 'chezmoi buf)
                            (point-min)))
                 (end (next-single-property-change start 'chezmoi buf)))
            (when (and end (> end start))
              (funcall f start end buffer-or-name)))
        (while (and (setq start (next-single-property-change end 'chezmoi buf))
                    (setq end (next-single-property-change start 'chezmoi buf)))
          (funcall f start end buffer-or-name))))))

(defun chezmoi-template-buffer-display (&optional display-p start buffer-or-name)
  "Display templates found in BUFFER-OR-NAME.
If called interactively, toggle display of templates in current buffer.
Use DISPLAY-P to set display of templates on or off.
START is passed to `chezmoi-template--funcall-over-display-properties'."
  (interactive (list (let ((display-p (not chezmoi-template--buffer-displayed-p)))
                       (setq-local chezmoi-template-display-p display-p)
                       display-p)
                     nil))
  (let ((buffer-or-name (or buffer-or-name (current-buffer))))
    (with-current-buffer buffer-or-name
      (chezmoi-template--cancel-display-timer)
      (remove-hook 'after-change-functions #'chezmoi-template--after-change t)
      (let ((was-modified-p (buffer-modified-p)))
        (setq chezmoi-template--buffer-displayed-p
              (and display-p chezmoi-template-display-p))
        (if chezmoi-template--buffer-displayed-p
            (chezmoi-template--funcall-over-matches
             #'chezmoi-template--put-display-value buffer-or-name)
          (chezmoi-template--funcall-over-display-properties
           #'chezmoi-template--remove-display-value start buffer-or-name))
        (unless was-modified-p
          (set-buffer-modified-p nil)))
      (add-hook 'after-change-functions
                #'chezmoi-template--after-change nil t))))

(defun chezmoi-template--cancel-display-timer ()
  "Cancel the pending template display refresh in the current buffer."
  (when (timerp chezmoi-template--display-timer)
    (cancel-timer chezmoi-template--display-timer))
  (setq chezmoi-template--display-timer nil))

(defun chezmoi-template--refresh-after-change (buffer)
  "Refresh displayed templates in BUFFER after an idle delay."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq chezmoi-template--display-timer nil)
      (when chezmoi-template--buffer-displayed-p
        (chezmoi-template-buffer-display nil)
        (chezmoi-template-buffer-display t)))))

(defun chezmoi-template--after-change (_ _ _)
  "Schedule a refresh of displayed templates after an idle delay."
  (when chezmoi-template--buffer-displayed-p
    (chezmoi-template--cancel-display-timer)
    (setq chezmoi-template--display-timer
          (run-with-idle-timer chezmoi-template-display-delay nil
                               #'chezmoi-template--refresh-after-change
                               (current-buffer)))))

(provide 'chezmoi-template)

;;; chezmoi-template.el ends here
