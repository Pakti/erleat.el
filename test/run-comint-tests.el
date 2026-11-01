;;; run-comint-tests.el --- Batch entry point for Erlang Comint extensions -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; emacs -Q --batch -L /path/to/erlang-mode -l test/run-comint-tests.el
;; No Eat dependency. The rebar3 integration test skips if unavailable.

(require 'package)
(package-initialize)

(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (add-to-list 'load-path directory)
  (dolist (file '("erlang-comint-redraw-tests.el" "erlang-shell-highlight-tests.el"))
    (load (expand-file-name file directory) nil t t)))

(ert-run-tests-batch-and-exit "^erlang-\\(?:comint-redraw\\|shell-highlight\\)-test-")
;;; run-comint-tests.el ends here
