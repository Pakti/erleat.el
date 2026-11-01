;;; erleat-load-all.el --- Development helper to reload Erleat sources -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-only

;;; Commentary:

;; This is a convenience library for Erleat development, not a user-facing
;; entry point.  Users should load `erleat' with (require 'erleat), and
;; should not load this library or add it to their initialization files.
;;
;; During development, use M-x load-file on this file to reload local edits.
;; Erleat libraries are loaded from their sibling .el sources, even if
;; already loaded or an older .elc file exists.  Erlang mode and Eat are
;; dependencies; this helper does not reload their libraries or start a shell.
;; Existing defvar/defcustom values are preserved by normal load semantics.

;;; Code:

(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  ;; Keep this checkout available to the libraries' autoloaded functions.
  (add-to-list 'load-path directory)
  (dolist (file '("erleat-highlight.el"
                  "erleat.el"))
    (load (expand-file-name file directory) nil nil t)))

(provide 'erleat-load-all)

;;; erleat-load-all.el ends here
