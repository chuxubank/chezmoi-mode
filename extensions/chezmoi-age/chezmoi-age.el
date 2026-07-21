;;; chezmoi-age.el --- Age integration for chezmoi -*- lexical-binding: t -*-

;; Author: Harrison Pielke-Lombardo
;; Maintainer: Harrison Pielke-Lombardo
;; Version: 1.4.10
;; Package-Requires: ((emacs "29.1") (age "0.1.4") (chezmoi-mode "1.4.10"))
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

;; Provides `age' integration for `chezmoi'.

;;; Code:
(require 'chezmoi-mode)
(require 'subr-x)

(defun chezmoi-age-get-recipients ()
  "Get age recipients."
  (let* ((config (chezmoi-get-config))
	 (recipient (gethash "recipient" (gethash "age" config)))
	 (recipients (gethash "recipients" (gethash "age" config))))
    (append (if (string-empty-p recipient) nil (list recipient)) recipients)))

(defun chezmoi-age-get-identity ()
  "Get age recipients."
  (let ((config (chezmoi-get-config)))
    (gethash "identity" (gethash "age" config))))

(provide 'chezmoi-age)

;;; chezmoi-age.el ends here
