;;; chezmoi-cape.el --- Cape completion for chezmoi -*- lexical-binding: t -*-

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

;; Provides a `cape' backend for `chezmoi'.

;;; Code:

(require 'chezmoi)

(defvar chezmoi-cape--properties
  (list :annotation-function (lambda (_) " Keyword")
	:company-kind (lambda (_) 'keyword)
	:exclusive 'no)
  "Completion extra properties for `chezmoi-cape'.")

(defun chezmoi-cape--next-keys (str)
  "Return candidates for STR for company completion.
Candidates are chezmoi data values corresponding to the path at point."
  (let* ((keys (thread-last chezmoi-template-key-regex
				    (split-string str)
				    butlast
				    (remove "")))
		 (hashget (lambda (m k)
                            (when (hash-table-p m)
                              (gethash k m))))
	 (data (thread-last (chezmoi-get-data)
			    (cl-reduce hashget keys :initial-value))))
    (cond ((hash-table-p data) (hash-table-keys data))
          ((stringp data) (list data))
          (t nil))))

(defun chezmoi-cape--bounds (node)
  "Return completion bounds for the final segment of selector NODE."
  (save-excursion
    (goto-char (min (point) (treesit-node-end node)))
    (skip-syntax-backward "w_" (treesit-node-start node))
    (cons (point) (treesit-node-end node))))

(defun chezmoi-capf ()
  "Complete current template."
  (when-let ((node (chezmoi-template--selector-node-at-point)))
    (let* ((bounds (chezmoi-cape--bounds node))
           (beg (car bounds))
           (end (cdr bounds))
           (text (treesit-node-text node t))
           (candidates (chezmoi-cape--next-keys text)))
      `(,beg ,end
             ,(completion-table-dynamic (lambda (_) candidates))
             :category chezmoi-template
             ,@chezmoi-cape--properties))))

(provide 'chezmoi-cape)

;;; chezmoi-cape.el ends here
