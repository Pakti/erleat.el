;;; erlang-shell-highlight-tests.el --- Comint highlighting tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'erlang-shell-highlight)

(defun erlang-shell-highlight-test--regions (face)
  (mapcar (lambda (overlay)
            (buffer-substring-no-properties (overlay-start overlay) (overlay-end overlay)))
          (cl-remove-if-not (lambda (o) (eq (overlay-get o 'face) face))
                            erlang-shell-highlight--overlays)))

(ert-deftest erlang-shell-highlight-test-bounds ()
  (dolist (text '("" "\n\n" "   \n   \n" "  indented\n"))
    (with-temp-buffer
      (insert text)
      (should-not (erlang-shell-highlight--bounds (point-min) (point-max)))))
  (with-temp-buffer
    (insert "OUTPUT\n{ok,\n 42}\n\n")
    (let ((bounds (erlang-shell-highlight--bounds (point-min) (point-max))))
      (should (equal (buffer-substring (car bounds) (cdr bounds)) "{ok,\n 42}")))))

(ert-deftest erlang-shell-highlight-test-custom-font-lock ()
  (let* ((calls 0) (source-hooks 0)
         (erlang-mode-hook (list (lambda () (cl-incf source-hooks))))
         (prog-mode-hook erlang-mode-hook)
         (erlang-shell-highlight-font-lock-add-keywords-function
          (lambda ()
            (cl-incf calls)
            (should (eq major-mode 'erlang-mode))
            (font-lock-add-keywords nil '(("," . font-lock-keyword-face)
                                          ("[{}]" . font-lock-type-face))))))
    (with-temp-buffer
      (insert "{ok,42,\"returned value\"}")
      (let ((text (buffer-string)))
        (set-buffer-modified-p nil)
        (erlang-shell-highlight--result (point-min) (point-max))
        (should (equal-including-properties text (buffer-string)))
        (should-not (buffer-modified-p)))
      (should (= calls 1))
      (should (= source-hooks 0))
      (should (equal (erlang-shell-highlight-test--regions 'font-lock-string-face)
                     '("\"returned value\"")))
      (should (equal (erlang-shell-highlight-test--regions 'font-lock-keyword-face)
                     '("," ",")))
      (should (equal (erlang-shell-highlight-test--regions 'font-lock-type-face)
                     '("}" "{"))))))

(ert-deftest erlang-shell-highlight-test-mode-lifecycle ()
  (with-temp-buffer
    (comint-mode)
    (should-error (erlang-shell-highlight-mode 1) :type 'user-error)
    (let ((erlang-input-ring-file-name nil)) (erlang-shell-mode))
    (let ((binding (key-binding (kbd "RET"))))
      (erlang-shell-highlight-mode 1)
      (erlang-shell-highlight-mode 1)
      (should (eq binding (key-binding (kbd "RET"))))
      (insert "result")
      (erlang-shell-highlight--result (point-min) (point-max))
      (should erlang-shell-highlight--overlays)
      (let ((marker (copy-marker (point-min))))
        (setq erlang-shell-highlight--start marker)
        (erlang-shell-highlight-mode -1)
        (should (= (marker-position marker) (point-min))))
      (should-not erlang-shell-highlight--overlays)
      (should-not (memq #'erlang-shell-highlight--finish comint-output-filter-functions))
      (should (eq binding (key-binding (kbd "RET")))))))

(ert-deftest erlang-shell-highlight-test-synchronous-output-and-partial-prompt ()
  (with-temp-buffer
    (let ((erlang-input-ring-file-name nil)) (erlang-shell-mode))
    (let ((process (make-pipe-process :name "highlight-test" :buffer (current-buffer)
                                      :noquery t :filter #'comint-output-filter)))
      (unwind-protect
          (progn
            (setq-local comint-process-echoes nil)
            (erlang-shell-highlight-mode 1)
            (comint-output-filter process "1> ")
            (goto-char (point-max)) (insert "expression.")
            (let ((comint-input-sender
                   (lambda (p _input)
                     (comint-output-filter p "OUTPUT\n{ok,\"text\"}\n")
                     (should-not erlang-shell-highlight--overlays)
                     (comint-output-filter p "2")
                     (should-not erlang-shell-highlight--overlays))))
              (comint-send-input))
            (should-not erlang-shell-highlight--overlays)
            (goto-char (point-max))
            (insert "  unfinished")
            (comint-output-filter process "> ")
            (should (string-suffix-p "2>   unfinished" (buffer-string)))
            (should (equal (erlang-shell-highlight-test--regions 'erlang-shell-highlight-output)
                           '("OUTPUT\n")))
            (should (equal (erlang-shell-highlight-test--regions 'erlang-shell-highlight-result)
                           '("{ok,\"text\"}")))
            (should (equal (erlang-shell-highlight-test--regions 'font-lock-string-face)
                           '("\"text\"")))
            (let ((count (length erlang-shell-highlight--overlays)))
              (comint-output-filter process "ASYNC\n2> ")
              (should (= count (length erlang-shell-highlight--overlays))))
            (delete-region (process-mark process) (point-max))
            (goto-char (point-max)) (insert "another_expression.")
            (let ((comint-input-sender
                   (lambda (p _input)
                     (comint-output-filter p "MULTI\n{ok,\n 42}\n3> "))))
              (comint-send-input))
            (should (equal (car (erlang-shell-highlight-test--regions
                                 'erlang-shell-highlight-result))
                           "{ok,\n 42}")))
        (delete-process process)))))

(ert-deftest erlang-shell-highlight-test-disabled-advice-delegates ()
  (with-temp-buffer
    (let (seen)
      (should (equal (erlang-shell-highlight--send
                      (lambda (&rest args) (setq seen args) 'returned) 1 2)
                     'returned))
      (should (equal seen '(1 2))))))

(provide 'erlang-shell-highlight-tests)
;;; erlang-shell-highlight-tests.el ends here
