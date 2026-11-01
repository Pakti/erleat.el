;;; erlang-comint-redraw-tests.el --- Redraw regression tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Independent of Eat.  Run with:
;; emacs -Q --batch -L . -L /path/to/otp/lib/tools/emacs \
;;   -l test/erlang-comint-redraw-tests.el -f ert-run-tests-batch-and-exit
;; Set ERLANG_COMINT_REDRAW_REBAR3 to override the rebar3 executable.

(require 'ert)
(require 'cl-lib)
(require 'erlang-comint-redraw)

(defun erlang-comint-redraw-test--chunks (chunks expected)
  (with-temp-buffer
    (setq erlang-comint-redraw--expected (list expected))
    (unwind-protect
        (mapconcat #'erlang-comint-redraw--filter chunks "")
      (erlang-comint-redraw--cancel-timer))))

(ert-deftest erlang-comint-redraw-test-every-split ()
  (dolist (pair '(("\e[A\e[J1> f().\r\n" . "1> f().\r\n")
                  ("\e[A\e[A\e[J2> 1 +\r\n   2.\r\n" . "2> 1 +\r\n   2.\r\n")
                  ("\e[2A\e[0J3> α().\n" . "3> α().\n")))
    (let ((raw (concat "echo\n" (car pair) "result\n4> ")))
      (dotimes (split (1+ (length raw)))
        (should (equal (erlang-comint-redraw-test--chunks
                        (list (substring raw 0 split) (substring raw split)) (cdr pair))
                       "echo\nresult\n4> ")))
      (should (equal (erlang-comint-redraw-test--chunks
                      (mapcar #'char-to-string (string-to-list raw)) (cdr pair))
                     "echo\nresult\n4> ")))))

(ert-deftest erlang-comint-redraw-test-preserves-unknown-output ()
  (dolist (raw '("ordinary output\n1> f().\n" "\e[31mred\e[0m\n"
                 "\e[A\e[J1> different().\n" "\e[2Jscreen\n"
                 "\e[A\e[K1> f().\n"))
    (dotimes (split (1+ (length raw)))
      (should (equal (erlang-comint-redraw-test--chunks
                      (list (substring raw 0 split) (substring raw split)) "1> f().\n")
                     raw)))))

(ert-deftest erlang-comint-redraw-test-only-one-redraw ()
  (let ((raw "\e[A\e[J1> f().\n"))
    (should (equal (erlang-comint-redraw-test--chunks (list (concat raw raw)) "1> f().\n")
                   raw))))

(ert-deftest erlang-comint-redraw-test-bounded-candidates ()
  (let ((raw (concat "\e[" (make-string 300 ?1))))
    (should (equal (erlang-comint-redraw-test--chunks (list raw) "1> f().\n") raw))))

(ert-deftest erlang-comint-redraw-test-mode-lifecycle ()
  (with-temp-buffer
    (should-error (erlang-comint-redraw-mode 1) :type 'user-error)
    (comint-mode)
    (erlang-comint-redraw-mode 1)
    (erlang-comint-redraw-mode 1)
    (should (= 1 (cl-count #'erlang-comint-redraw--filter comint-preoutput-filter-functions)))
    (erlang-comint-redraw-mode -1)
    (should-not (memq #'erlang-comint-redraw--filter comint-preoutput-filter-functions))))

(defun erlang-comint-redraw-test--wait (process regexp)
  (let ((deadline (+ (float-time) 10)))
    (while (and (< (float-time) deadline)
                (not (save-excursion
                       (goto-char (process-mark process))
                       (let ((inhibit-field-text-motion t))
                         (beginning-of-line)
                         (looking-at regexp)))))
      (accept-process-output process 0.03))
    (save-excursion
      (goto-char (process-mark process))
      (let ((inhibit-field-text-motion t))
        (beginning-of-line)
        (should (looking-at regexp))))))

(ert-deftest erlang-comint-redraw-test-timeout-and-disable-flush ()
  (with-temp-buffer
    (comint-mode)
    (let* ((buffer (current-buffer))
           (process (make-pipe-process :name "redraw-flush-test" :buffer buffer
                                       :noquery t :filter #'comint-output-filter))
           (erlang-comint-redraw-timeout 0.01))
      (unwind-protect
          (progn
            (erlang-comint-redraw-mode 1)
            (setq erlang-comint-redraw--expected '("1> f().\n"))
            (comint-output-filter process "\e[A\e[J1> f")
            (should (equal (buffer-string) ""))
            (let ((deadline (+ (float-time) 1)))
              (while (and erlang-comint-redraw--timer (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            ;; Comint may interpret controls, but the text must not disappear.
            (should (string-suffix-p "1> f" (buffer-string)))
            (setq erlang-comint-redraw--expected '("1> f().\n"))
            (comint-output-filter process "\e[A\e[J1> f")
            (erlang-comint-redraw-mode -1)
            (should (string-suffix-p "1> f1> f" (buffer-string)))
            (should-not erlang-comint-redraw--timer))
        (delete-process process)))))

(ert-deftest erlang-comint-redraw-test-real-rebar3 ()
  (require 'erlang)
  (let* ((program (or (getenv "ERLANG_COMINT_REDRAW_REBAR3") (executable-find "rebar3")))
         (buffer (and program (generate-new-buffer " *erlang-redraw-test*")))
         (directory (and program (make-temp-file "erlang-redraw-test-" t)))
         process)
    (skip-unless program)
    (unwind-protect
        (with-current-buffer buffer
          (let ((default-directory (file-name-as-directory directory))
                (comint-terminfo-terminal "xterm")
                (erlang-input-ring-file-name nil))
            (make-comint-in-buffer "erlang-redraw-test" buffer program nil "shell")
            (setq process (get-buffer-process buffer))
            (set-process-query-on-exit-flag process nil)
            (erlang-shell-mode)
            (setq-local comint-process-echoes t)
            (erlang-comint-redraw-mode 1)
            (let ((raw ""))
              (add-hook 'comint-preoutput-filter-functions
                        (lambda (s) (setq raw (concat raw s)) s) nil t)
              (erlang-comint-redraw-test--wait process "1> ")
              (cl-labels ((send (s)
                            (goto-char (point-max))
                            (insert s)
                            (comint-send-input)))
		(send "io:format(\"PRINTED~n\"), {ok, 42}.")
		(erlang-comint-redraw-test--wait process "2> ")
		(should (string-match-p "1> io:format(\"PRINTED~n\"), {ok, 42}\.\nPRINTED\n{ok,42}\n2> "
					(buffer-string)))
		(save-excursion
                  (goto-char (point-min))
                  (search-forward "1> ")
                  (should (eq (get-text-property (point) 'font-lock-face)
                              'comint-highlight-input))
                  (should (memq 'comint-highlight-prompt
				(ensure-list (get-text-property (- (point) 3)
								'font-lock-face)))))
		(send "1 +")
		(erlang-comint-redraw-test--wait process "\\.\\. ")
		(send "2.")
		(erlang-comint-redraw-test--wait process "3> ")
		(send "code:which(r3).")
		(erlang-comint-redraw-test--wait process "4> ")
		(should (string-match-p "r3.beam" (buffer-string)))
		;; Async output must leave unsent local input intact.
		(send "spawn(fun() -> timer:sleep(200), io:format(\"ASYNC~n\") end).")
		(erlang-comint-redraw-test--wait process "5> ")
		(goto-char (point-max)) (insert "unfinished")
		(let ((deadline (+ (float-time) 3)))
                  (while (and (< (float-time) deadline)
                              (not (string-match-p "ASYNC\n5> unfinished" (buffer-string))))
                    (accept-process-output process 0.03)))
		(should (string-match-p "ASYNC\n5> unfinished" (buffer-string)))
		;; Exercise the original helper, preserving unsent input.
		(let ((inferior-erlang-process process)
                      (inferior-erlang-buffer buffer))
                  (inferior-erlang-send-command "erlang:length([1,2,3]).")
                  (erlang-comint-redraw-test--wait process "6> ")
                  (should (string-suffix-p "6> unfinished" (buffer-string)))
                  ;; Exercise upstream compilation, without replacing its code.
                  (let ((file (expand-file-name "redraw_test.erl" directory))
			(next-error-last-buffer nil))
                    (with-temp-buffer
                      (setq buffer-file-name file)
                      (insert "-module(redraw_test).\n-export([value/0]).\nvalue() -> 42.\n")
                      (write-region (point-min) (point-max) file nil 'silent)
                      (set-buffer-modified-p nil)
                      (save-window-excursion
			(switch-to-buffer (current-buffer))
			(inferior-erlang-compile nil)))
                    (erlang-comint-redraw-test--wait process "7> ")
                    (should (file-exists-p (expand-file-name "redraw_test.beam" directory)))
                    (should (string-suffix-p "7> unfinished" (buffer-string)))))
		;; Verify the test really used the modern terminal redraw path.
		(should (string-match-p "\e\\[A\e\\[J" raw))
		(let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should-not (string-match-p "\e" text))
                  (dolist (prompt '("1> " "2> " "3> " "4> " "5> " "6> " "7> "))
                    (should (= 1 (cl-count-if
                                  (lambda (line) (string-prefix-p prompt line))
                                  (split-string text "\n"))))))))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory directory t))))

;;; erlang-comint-redraw-tests.el ends here
