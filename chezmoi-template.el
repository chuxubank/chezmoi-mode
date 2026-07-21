;;; chezmoi-template.el --- Display chezmoi templates -*- lexical-binding: t -*-

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
(require 'subr-x)
(require 'chezmoi-core)
(require 'cl-lib)
(require 'treesit)

(declare-function chezmoi-template-source-file-p "chezmoi-core" (file))
(declare-function chezmoi-get-data "chezmoi-mode" ())
(declare-function pm-map-over-spans
                  "polymode-core"
                  (function &optional beg end count backwardp visibly no-cache))

(defvar chezmoi-mode)

(defvar chezmoi-template-mode-hook nil
  "Hook run when a Chezmoi template source needs a template-aware mode.
It runs before completion and template display are initialized, but is skipped
when Polymode is already active.  Hook functions may select a suitable major
mode for the template source file.")

;;;###autoload
(defun chezmoi-template-normalize-host-filename (filename)
  "Translate chezmoi source attributes in host FILENAME."
  (if (and filename chezmoi-root
           (file-in-directory-p filename chezmoi-root))
      (chezmoi--unchezmoi-source-file-name filename)
    filename))

(defcustom chezmoi-template-display-p t
  "Whether to display templates."
  :type '(boolean)
  :group 'chezmoi-mode-settings
  :local t)

(defcustom chezmoi-template-display-delay 0.2
  "Idle delay before refreshing displayed template values after a change."
  :type '(number)
  :group 'chezmoi-mode-settings)

(defcustom chezmoi-template-completion-cache-duration 1.0
  "Seconds to reuse Chezmoi data while completing template selectors.
Set this to zero to query Chezmoi on every completion request."
  :type '(number)
  :group 'chezmoi-mode-settings)

(defvar-local chezmoi-template--buffer-displayed-p nil
  "Whether all templates are currently displayed in buffer.")

(defvar-local chezmoi-template--display-timer nil
  "Pending idle timer for refreshing displayed template values.")

(defvar-local chezmoi-template--completion-buffers nil
  "Buffers where Chezmoi template completion was installed.")

(defvar-local chezmoi-template--completion-enabled-p nil
  "Whether new Go Template parser buffers should receive completion.")

(defvar-local chezmoi-template--refresh-buffers nil
  "Buffers where Chezmoi template refresh hooks were installed.")

(defvar-local chezmoi-template--refresh-enabled-p nil
  "Whether new Go Template parser buffers should receive refresh hooks.")

(defvar-local chezmoi-template--completion-data-cache nil
  "Cached Chezmoi completion data as a (TIMESTAMP . DATA) pair.")

(defvar chezmoi-template-key-regex "\\."
  "Regex for splitting keys.")

(defun chezmoi-template--gotmpl-parser-p ()
  "Return non-nil when the current buffer has a Go Template parser."
  (and (treesit-ready-p 'gotmpl)
       (cl-some (lambda (parser)
                  (eq (treesit-parser-language parser) 'gotmpl))
                (treesit-parser-list))))

(defun chezmoi-template--base-buffer (&optional buffer-or-name)
  "Return the base buffer for BUFFER-OR-NAME or the current buffer."
  (with-current-buffer (or buffer-or-name (current-buffer))
    (or (buffer-base-buffer) (current-buffer))))

(defun chezmoi-template--map-gotmpl-spans (function &optional buffer-or-name)
  "Call FUNCTION for each Go Template span in BUFFER-OR-NAME.
FUNCTION receives the Polymode span and runs in the buffer that owns its
`gotmpl' parser.  A non-Polymode buffer is represented by one full-buffer span."
  (with-current-buffer (chezmoi-template--base-buffer buffer-or-name)
    (if (and (bound-and-true-p polymode-mode)
             (fboundp 'pm-map-over-spans))
        (save-current-buffer
          (pm-map-over-spans
           (lambda (span)
             (when (chezmoi-template--gotmpl-parser-p)
               (funcall function span)))))
      (when (chezmoi-template--gotmpl-parser-p)
        (funcall function (list nil (point-min) (point-max)))))))

(defun chezmoi-template-buffer-p (&optional buffer-or-name)
  "Return non-nil when BUFFER-OR-NAME has Go Template capabilities."
  (catch 'gotmpl-parser
    (chezmoi-template--map-gotmpl-spans
     (lambda (_span) (throw 'gotmpl-parser t))
     buffer-or-name)
    nil))

(defun chezmoi-template-execute (template)
  "Convert TEMPLATE using chezmoi and return its output."
  (with-temp-buffer
    (call-process chezmoi-command nil t nil "execute-template" template)
    (buffer-string)))

(defun chezmoi-template--selector-node-at-point ()
  "Return the Go template selector node at point, if any."
  (when (chezmoi-template--gotmpl-parser-p)
    (let ((node (treesit-node-at (max (point-min) (1- (point))) 'gotmpl))
          field)
      (while (and node
                  (not (equal (treesit-node-type node)
                              "selector_expression")))
        (when (equal (treesit-node-type node) "field")
          (setq field node))
        (setq node (treesit-node-parent node)))
      (or node field))))

(defvar chezmoi-template--completion-properties
  (list :annotation-function (lambda (_) " Keyword")
        :company-kind (lambda (_) 'keyword)
        :exclusive 'no)
  "Extra properties returned by `chezmoi-capf'.")

(defun chezmoi-template--completion-data ()
  "Return recently queried Chezmoi data for the current base buffer."
  (with-current-buffer (chezmoi-template--base-buffer)
    (let ((now (float-time)))
      (if (and chezmoi-template--completion-data-cache
               (< (- now (car chezmoi-template--completion-data-cache))
                  (max 0 chezmoi-template-completion-cache-duration)))
          (cdr chezmoi-template--completion-data-cache)
        (let ((data (chezmoi-get-data)))
          (setq chezmoi-template--completion-data-cache (cons now data))
          data)))))

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
                          :initial-value
                          (chezmoi-template--completion-data))))
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

(defun chezmoi-template--set-parser-hook
    (enabled registry hook function include-base &optional buffer-or-name)
  "Set FUNCTION on HOOK in parser buffers when ENABLED.
REGISTRY is the base-buffer-local variable that tracks installed buffers.
When INCLUDE-BASE is non-nil, install the hook in the base buffer as well.
Return non-nil when at least one `gotmpl' parser was found."
  (let* ((base-buffer (chezmoi-template--base-buffer buffer-or-name))
         (buffers
          (cl-delete-if-not
           #'buffer-live-p (buffer-local-value registry base-buffer)))
         found)
    (if enabled
        (cl-labels ((install ()
                      (cl-pushnew (current-buffer) buffers)
                      (add-hook hook function nil t)))
          (when include-base
            (with-current-buffer base-buffer
              (install)))
          (chezmoi-template--map-gotmpl-spans
           (lambda (_span)
             (setq found t)
             (install))
           base-buffer)
          (with-current-buffer base-buffer
            (set (make-local-variable registry) buffers)))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (remove-hook hook function t))))
      (with-current-buffer base-buffer
        (set (make-local-variable registry) nil)))
    found))

(defun chezmoi-template--install-current-buffer-hook
    (base-buffer registry hook function)
  "Install FUNCTION on HOOK and track this buffer in BASE-BUFFER's REGISTRY."
  (let ((buffer (current-buffer)))
    (add-hook hook function nil t)
    (with-current-buffer base-buffer
      (let ((buffers
             (cl-delete-if-not
              #'buffer-live-p (symbol-value registry))))
        (cl-pushnew buffer buffers)
        (set registry buffers)))))

(defun chezmoi-template--install-inner-buffer-hooks ()
  "Install requested Chezmoi hooks in a new Polymode inner buffer."
  (when-let ((base-buffer (buffer-base-buffer)))
    (let ((completion-enabled-p
           (buffer-local-value
            'chezmoi-template--completion-enabled-p base-buffer))
          (refresh-enabled-p
           (buffer-local-value
            'chezmoi-template--refresh-enabled-p base-buffer)))
      (when (and (or completion-enabled-p refresh-enabled-p)
                 (chezmoi-template--gotmpl-parser-p))
        (when completion-enabled-p
          (chezmoi-template--install-current-buffer-hook
           base-buffer 'chezmoi-template--completion-buffers
           'completion-at-point-functions #'chezmoi-capf))
        (when refresh-enabled-p
          (chezmoi-template--install-current-buffer-hook
           base-buffer 'chezmoi-template--refresh-buffers
           'after-change-functions #'chezmoi-template--after-change))))))

(defun chezmoi-template-set-completion (enabled &optional buffer-or-name)
  "Set Chezmoi template completion to ENABLED in BUFFER-OR-NAME.
In a Polymode buffer, update each inner buffer that owns a `gotmpl' parser.
Return non-nil when at least one compatible parser was found."
  (let ((base-buffer (chezmoi-template--base-buffer buffer-or-name)))
    (with-current-buffer base-buffer
      (setq chezmoi-template--completion-enabled-p enabled))
    (prog1
        (chezmoi-template--set-parser-hook
         enabled 'chezmoi-template--completion-buffers
         'completion-at-point-functions #'chezmoi-capf nil base-buffer)
      (unless enabled
        (with-current-buffer base-buffer
          (setq chezmoi-template--completion-data-cache nil))))))

(defun chezmoi-template--selector-action-span (node)
  "Return the complete action span when NODE is its only expression."
  (unless (equal (treesit-node-type (treesit-node-parent node))
                 "selector_expression")
    (save-excursion
      (goto-char (treesit-node-start node))
      (when (re-search-backward "{{-?" nil t)
        (let ((start (match-beginning 0))
              (content-start (match-end 0)))
          (goto-char (treesit-node-end node))
          (when (re-search-forward "-?}}" nil t)
            (let ((content-end (match-beginning 0))
                  (end (match-end 0)))
              (when (and
                     (string-match-p
                      "\\`[[:space:]]*\\'"
                      (buffer-substring-no-properties
                       content-start (treesit-node-start node)))
                     (string-match-p
                      "\\`[[:space:]]*\\'"
                      (buffer-substring-no-properties
                       (treesit-node-end node) content-end)))
                (cons start end)))))))))

(defun chezmoi-template--treesit-expression-spans (&optional minimum maximum)
  "Return simple Go template expression spans from MINIMUM to MAXIMUM.
The bounds default to the beginning and end of the current buffer.
Only direct selector expressions such as `{{ .foo }}' are returned."
  (when (chezmoi-template--gotmpl-parser-p)
    (let ((minimum (or minimum (point-min)))
          (maximum (or maximum (point-max)))
          spans)
      (dolist (capture
               (treesit-query-capture
                (treesit-buffer-root-node 'gotmpl)
                '((selector_expression) @selector
                  (field) @selector)
                minimum maximum))
        (when-let ((span (chezmoi-template--selector-action-span
                          (cdr capture))))
          (when (and (<= minimum (car span))
                     (<= (cdr span) maximum))
            (push span spans))))
      (nreverse spans))))

(defun chezmoi-template--put-display-value (start end value &optional object)
  "Display the VALUE from START to END in string or buffer OBJECT."
  (unless (string-match-p chezmoi-command-error-regex value)
    (with-silent-modifications
      (put-text-property start end 'display value object)
      (put-text-property start end 'chezmoi t object))))

(defun chezmoi-template--remove-display-value (start end &optional object)
  "Remove the displayed template from START to END in OBJECT."
  (when (and start end)
    (with-silent-modifications
      (remove-text-properties start end '(display nil chezmoi nil) object))))

(defun chezmoi-template--batch-token (kind templates)
  "Return a unique batch token for KIND and TEMPLATES."
  (format "__chezmoi_mode_%s_%s__"
          kind
          (secure-hash
           'sha1 (format "%S%s%s" templates (current-time) (random)))))

(defun chezmoi-template--selector-keys (template)
  "Return the field keys from a simple selector TEMPLATE."
  (let ((start (cond ((string-prefix-p "{{-" template) 3)
                     ((string-prefix-p "{{" template) 2)))
        (end (cond ((string-suffix-p "-}}" template) 3)
                   ((string-suffix-p "}}" template) 2))))
    (when (and start end)
      (let ((selector (string-trim
                       (substring template start (- end)))))
        (when (string-match-p
               "\\`\\.[[:alnum:]_.]+\\'" selector)
          (split-string (substring selector 1) "\\." t))))))

(defun chezmoi-template--dig-expression (template missing-token)
  "Return a missing-safe expression for selector TEMPLATE.
Use MISSING-TOKEN as the fallback value."
  (when-let ((keys (chezmoi-template--selector-keys template)))
    (format "{{ dig %s %S . }}"
            (mapconcat #'prin1-to-string keys " ")
            missing-token)))

(defun chezmoi-template--execute-many (templates)
  "Execute simple TEMPLATES in one Chezmoi invocation.
Return nil for selectors whose field path is missing."
  (cond
   ((null templates) nil)
   (t
    (let* ((delimiter (chezmoi-template--batch-token "separator" templates))
           (missing-token (chezmoi-template--batch-token "missing" templates))
           (expressions
            (mapcar (lambda (template)
                      (or (chezmoi-template--dig-expression
                           template missing-token)
                          template))
                    templates))
           (output
            (chezmoi-template-execute
             (string-join expressions delimiter)))
           (values
            (if (cdr templates)
                (split-string output (regexp-quote delimiter) nil)
              (list output))))
      (unless (= (length values) (length templates))
        (setq values (make-list (length templates) output)))
      (mapcar (lambda (value)
                (unless (string-equal value missing-token)
                  value))
              values)))))

(defun chezmoi-template--funcall-over-spans (f spans buffer-or-name)
  "Call F for SPANS in BUFFER-OR-NAME after executing their expressions."
  (with-current-buffer buffer-or-name
    (let* ((templates
            (mapcar (lambda (span)
                      (buffer-substring-no-properties
                       (car span) (cdr span)))
                    spans))
           (values (chezmoi-template--execute-many templates)))
      (cl-mapc (lambda (span value)
                 (when value
                   (funcall f (car span) (cdr span) value buffer-or-name)))
               spans values))))

(defun chezmoi-template--funcall-over-matches (f buffer-or-name)
  "Call F on each matching template in BUFFER-OR-NAME.
F is called with the start of the match, the end of the match,
the template value and BUFFER-OR-NAME.  Return non-nil when a compatible
parser was found."
  (let (found spans)
    (chezmoi-template--map-gotmpl-spans
     (lambda (span)
       (setq found t)
       (setq spans
             (nconc spans
                    (chezmoi-template--treesit-expression-spans
                     (nth 1 span) (nth 2 span)))))
     buffer-or-name)
    (chezmoi-template--funcall-over-spans f spans buffer-or-name)
    found))

(defun chezmoi-template--funcall-over-display-properties (f start buffer-or-name)
  "Call F on each occurrence with display property in BUFFER-OR-NAME.
F is called with the start and end of the occurrence and BUFFER-OR-NAME.
When START is non-nil, find only the region around START."
  (with-current-buffer buffer-or-name
    (let ((minimum (point-min))
          (maximum (point-max))
          (buf (current-buffer)))
      (if start
          (let* ((position (min (max start minimum) maximum))
                 (probe
                  (cond
                   ((and (< position maximum)
                         (get-text-property position 'chezmoi buf))
                    position)
                   ((and (> position minimum)
                         (get-text-property (1- position) 'chezmoi buf))
                    (1- position)))))
            (when probe
              (funcall
               f
               (or (previous-single-property-change
                    (1+ probe) 'chezmoi buf minimum)
                   minimum)
               (or (next-single-property-change
                    probe 'chezmoi buf maximum)
                   maximum)
               buffer-or-name)))
        (let ((position minimum))
          (while (< position maximum)
            (let ((end
                   (or (next-single-property-change
                        position 'chezmoi buf maximum)
                       maximum)))
              (when (get-text-property position 'chezmoi buf)
                (funcall f position end buffer-or-name))
              (setq position end))))))))

(defun chezmoi-template-buffer-display (&optional display-p start buffer-or-name)
  "Display templates found in BUFFER-OR-NAME.
If called interactively, toggle display of templates in current buffer.
Use DISPLAY-P to set display of templates on or off.
START is passed to `chezmoi-template--funcall-over-display-properties'."
  (interactive
   (with-current-buffer (chezmoi-template--base-buffer)
     (let ((display-p (not chezmoi-template--buffer-displayed-p)))
       (setq-local chezmoi-template-display-p display-p)
       (list display-p nil))))
  (let ((buffer-or-name
         (chezmoi-template--base-buffer buffer-or-name)))
    (with-current-buffer buffer-or-name
      (chezmoi-template--cancel-display-timer)
      (chezmoi-template--set-refresh nil buffer-or-name)
      (if (and display-p chezmoi-template-display-p)
          (setq chezmoi-template--buffer-displayed-p
                (chezmoi-template--funcall-over-matches
                 #'chezmoi-template--put-display-value buffer-or-name))
        (setq chezmoi-template--buffer-displayed-p nil)
        (chezmoi-template--funcall-over-display-properties
         #'chezmoi-template--remove-display-value start buffer-or-name))
      (when (and chezmoi-mode chezmoi-template--buffer-displayed-p)
        (chezmoi-template--set-refresh t buffer-or-name)))))

(defun chezmoi-template--set-refresh (enabled &optional buffer-or-name)
  "Set template refresh hooks to ENABLED in BUFFER-OR-NAME and its spans."
  (let ((base-buffer (chezmoi-template--base-buffer buffer-or-name)))
    (with-current-buffer base-buffer
      (setq chezmoi-template--refresh-enabled-p enabled))
    (chezmoi-template--set-parser-hook
     enabled 'chezmoi-template--refresh-buffers
     'after-change-functions #'chezmoi-template--after-change t base-buffer)))

(defun chezmoi-template--cancel-display-timer ()
  "Cancel the pending template display refresh in the current buffer."
  (when (timerp chezmoi-template--display-timer)
    (cancel-timer chezmoi-template--display-timer))
  (setq chezmoi-template--display-timer nil))

(defun chezmoi-template--display-after-idle (buffer)
  "Display templates in BUFFER after an idle delay."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq chezmoi-template--display-timer nil)
      (when (and chezmoi-mode chezmoi-template-display-p)
        (chezmoi-template-buffer-display t)))))

(defun chezmoi-template-schedule-buffer-display (&optional parser-found-p)
  "Schedule initial template display for the current buffer.
When PARSER-FOUND-P is non-nil, skip checking for a Go Template parser."
  (chezmoi-template--cancel-display-timer)
  (when (and chezmoi-mode
             chezmoi-template-display-p
             (or parser-found-p (chezmoi-template-buffer-p)))
    (setq chezmoi-template--display-timer
          (run-with-idle-timer chezmoi-template-display-delay nil
                               #'chezmoi-template--display-after-idle
                               (current-buffer)))))

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
  (let ((base-buffer (chezmoi-template--base-buffer)))
    (with-current-buffer base-buffer
      (when chezmoi-template--buffer-displayed-p
        (chezmoi-template--cancel-display-timer)
        (setq chezmoi-template--display-timer
              (run-with-idle-timer chezmoi-template-display-delay nil
                                   #'chezmoi-template--refresh-after-change
                                   base-buffer))))))

(with-eval-after-load 'polymode-core
  (add-hook 'polymode-init-inner-hook
            #'chezmoi-template--install-inner-buffer-hooks))

(provide 'chezmoi-template)

;;; chezmoi-template.el ends here
