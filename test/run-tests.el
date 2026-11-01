;;; run-tests.el --- Batch entry point for Erleat tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; From the checkout root: emacs -Q --batch -l test/run-tests.el
;; Add -L paths for dependencies not installed through package.el.

;;; Code:

(require 'package)
(package-initialize)

(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path directory)
  (require 'erleat-test-helper)
  (dolist (file '("erleat-tests.el" "erleat-highlight-tests.el"))
    (load (expand-file-name file directory) nil t t)))

(ert-run-tests-batch-and-exit "^erleat-test-")
;;; run-tests.el ends here
