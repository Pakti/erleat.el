;;; erleat-highlight-tests.el --- Result highlighting tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-only

;;; Code:

(require 'erleat-test-helper)

(ert-deftest erleat-test-result-01-output-and-syntax-and-fallback ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (should (eq (with-current-buffer buffer (key-binding (kbd "RET")))
                'erleat-send-input))
    (erleat-test--submit buffer "io:format(\"OUTPUT~n\"), {ok,42,\"text\"}.")
    (erleat-test--complete buffer 2)
    (should (equal (erleat-test--regions buffer 'erleat-output) '("OUTPUT\n")))
    (should (equal (erleat-test--regions buffer 'erleat-result) '("{ok,42,\"text\"}")))
    (should (equal (erleat-test--regions buffer 'font-lock-string-face) '("\"text\"")))))

(ert-deftest erleat-test-result-02-fast-consecutive-and-return-event ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (erleat-test--submit buffer "1+1." 'return)
    (erleat-test--complete buffer 2)
    (erleat-test--submit buffer "2+2.")
    (erleat-test--complete buffer 3)
    (should (equal (erleat-test--regions buffer 'erleat-result) '("4" "2")))
    (with-current-buffer buffer
      (should (= (length (cl-remove-if-not
                          (lambda (x) (eq x 'erleat-highlight--update)) eat-update-hook)) 1)))))

(ert-deftest erleat-test-result-03-multiline-input-and-result ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (erleat-test--submit buffer "begin")
    (erleat-test--wait buffer (lambda () (string-match-p "begin\n" (buffer-string))))
    (should-not (erleat-test--regions buffer 'erleat-result))
    (erleat-test--submit buffer "io:format(\"MULTI~n\"),")
    (erleat-test--wait buffer (lambda () (string-match-p "MULTI~n.*\n" (buffer-string))))
    (erleat-test--submit buffer "lists:seq(1,100) end.")
    (erleat-test--complete buffer 2)
    (should (equal (erleat-test--regions buffer 'erleat-output) '("MULTI\n")))
    (let ((result (car (erleat-test--regions buffer 'erleat-result))))
      (should (string-prefix-p "[1,2,3," result))
      (should (string-match-p "\n +" result)))))

(ert-deftest erleat-test-result-04-wrapping-and-wide-character-mapping ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (eat-term-resize eat-terminal 40 24))
      (set-process-window-size (get-buffer-process buffer) 24 40))
    (let ((string (concat (make-string 45 ?a) "TAIL")))
      (erleat-test--submit buffer (format "io:format(\"~ts~n\", [[955,38634]]), {'雪',\"%s\"}." string))
      (erleat-test--complete buffer 2)
      (should (equal (erleat-test--regions buffer 'erleat-output) '("λ雪\n")))
      (should (member (concat "\"" string "\"") (erleat-test--regions buffer 'font-lock-string-face))))))

(ert-deftest erleat-test-result-05-line-and-character-modes ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (with-current-buffer buffer
      (eat-char-mode)
      (should (eq (key-binding (kbd "RET")) 'erleat-send-input)))
    (erleat-test--submit buffer "3+3.")
    (erleat-test--complete buffer 2)
    (with-current-buffer buffer
      (eat-line-mode)
      (goto-char (point-max))
      (insert "4+4.")
      (let ((last-command-event ?\r)) (call-interactively (key-binding (kbd "RET")))))
    (erleat-test--complete buffer 3)
    (should (equal (erleat-test--regions buffer 'erleat-result) '("8" "6")))))

(ert-deftest erleat-test-result-06-empty-input-and-disable ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (with-current-buffer buffer
      (let ((last-command-event ?\r)) (call-interactively (key-binding (kbd "RET")))))
    (dotimes (_ 5) (accept-process-output nil 0.03))
    (should-not (erleat-test--regions buffer 'erleat-result))
    (erleat-test--submit buffer "5+5.")
    (erleat-test--complete buffer 2)
    (with-current-buffer buffer
      (erleat-highlight-mode -1)
      (should (eq (key-binding (kbd "RET")) 'erleat-send-input))
      (should-not erleat-highlight--results)
      (should erleat--highlight-overlays)
      (should-not (memq 'erleat-highlight--update eat-update-hook)))))

(ert-deftest erleat-test-result-07-helper-empty-and-indented-output ()
  (dolist (text '("" "\n\n" "   \n   \n" "  indented\n"))
    (with-temp-buffer
      (insert text)
      (should-not (erleat-highlight--result-bounds))))
  (with-temp-buffer
    (insert "OUTPUT\n{ok,\n 42}\n\n")
    (let ((bounds (erleat-highlight--result-bounds)))
      (should (equal (buffer-substring (car bounds) (cdr bounds)) "{ok,\n 42}")))))

(ert-deftest erleat-test-result-08-nondestructive-and-async-output ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (erleat-test--submit buffer "spawn(fun() -> timer:sleep(100), io:format(\"ASYNC~n\") end), ok.")
    (erleat-test--complete buffer 2)
    (erleat-test--wait buffer (lambda () (string-match-p "\nASYNC\n" (buffer-string))))
    (should (equal (erleat-test--regions buffer 'erleat-result) '("ok")))
    (with-current-buffer buffer
      (let ((text (buffer-string)) (count (length erleat-highlight--results)))
        (set-buffer-modified-p nil)
        (dotimes (_ 10) (erleat-highlight--update))
        (should (equal-including-properties text (buffer-string)))
        (should-not (buffer-modified-p))
        (should (= count (length erleat-highlight--results)))))
    (erleat-test--submit buffer "6+6.")
    (erleat-test--complete buffer 3)
    (should (equal (erleat-test--regions buffer 'erleat-result) '("12" "ok")))))



(ert-deftest erleat-test-result-09-custom-font-lock-function ()
  (let* ((calls 0)
         (source-hook-calls 0)
         (erlang-mode-hook
          (list (lambda () (setq source-hook-calls (1+ source-hook-calls)))))
         (prog-mode-hook erlang-mode-hook)
         (erleat-font-lock-add-keywords-function
          (lambda ()
            (setq calls (1+ calls))
            (should (eq major-mode 'erlang-mode))
            (should-not (derived-mode-p 'eat-mode))
            (font-lock-add-keywords
             nil '(("," . font-lock-keyword-face)
                   ("[{}]" . font-lock-type-face))))))
    (erleat-test-with-shell ((erleat-extra-highlight t))
      (erleat-test--submit buffer "io:format(\"OUTPUT~n\"), {ok,42,\"returned value\"}.")
      (erleat-test--complete buffer 2)
      (should (= calls 1))
      (should (= source-hook-calls 0))
      (should (equal (erleat-test--regions buffer 'erleat-output) '("OUTPUT\n")))
      (should (equal (erleat-test--regions buffer 'font-lock-keyword-face) '("," ",")))
      (should (equal (erleat-test--regions buffer 'font-lock-type-face) '("}" "{")))
      (should (equal (erleat-test--regions buffer 'font-lock-string-face) '("\"returned value\""))))))

(ert-deftest erleat-test-extra-01-default-disabled-keeps-basic-highlighting ()
  (should-not (default-value 'erleat-extra-highlight))
  (erleat-test-with-shell ((erleat-extra-highlight nil))
    (with-current-buffer buffer
      (should erleat-mode)
      (should-not erleat-highlight-mode)
      (should erleat--highlight-overlays)
      (should (eq (key-binding (kbd "RET")) 'erleat-send-input)))
    (erleat-test--submit buffer "1+2.")
    (erleat-test--wait buffer (lambda () (equal (erleat-test--prompt-number) 2)))
    (with-current-buffer buffer
      (should-not erleat-highlight--results)
      (should (cl-some (lambda (o) (eq (overlay-get o 'face) 'erleat-input))
                       erleat--highlight-overlays)))))

(ert-deftest erleat-test-extra-02-option-lifecycle-and-manual-toggle ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (should (buffer-local-value 'erleat-highlight-mode buffer))
    (erleat-test--submit buffer "io:format(\"OUTPUT~n\"), {ok,42}.")
    (erleat-test--complete buffer 2)
    (should (equal (erleat-test--regions buffer 'erleat-output) '("OUTPUT\n")))
    (should (equal (erleat-test--regions buffer 'erleat-result) '("{ok,42}")))
    (with-current-buffer buffer
      (erleat-mode -1)
      (should-not erleat-highlight-mode)
      (should-not erleat-highlight--results)
      (erleat-mode 1)
      (should erleat-highlight-mode)
      (setq erleat-extra-highlight nil)
      (should erleat-highlight-mode)
      (erleat-mode 1)
      (should-not erleat-highlight-mode)
      (erleat-highlight-mode 1)
      (should erleat-highlight-mode)
      (erleat-mode -1)
      (should-not erleat-highlight-mode))))

(ert-deftest erleat-test-extra-03-reuse-and-restart ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (with-current-buffer buffer (erleat-highlight-mode -1))
    (erleat)
    (should-not (buffer-local-value 'erleat-highlight-mode buffer))
    (let ((process (get-buffer-process buffer)))
      (erleat-test--send buffer "q().\r")
      (erleat-test--wait buffer (lambda () (not (process-live-p process)))))
    (erleat)
    (erleat-test--wait buffer (lambda () (erleat-test--prompt-number)) 10)
    (should (buffer-local-value 'erleat-highlight-mode buffer))))

(ert-deftest erleat-test-extra-04-readme-keymap-example ()
  (let* ((keys '("C-v" "C-c C-p" "C-c C-n"))
         (old (mapcar (lambda (key) (lookup-key erleat-mode-map (kbd key))) keys)))
    (unwind-protect
        (progn
          (with-eval-after-load 'erleat
            (define-key erleat-mode-map (kbd "C-v") #'eat-yank)
            (define-key erleat-mode-map (kbd "C-c C-p") #'erleat-previous-shell-prompt)
            (define-key erleat-mode-map (kbd "C-c C-n") #'erleat-next-shell-prompt))
          (erleat-test-with-shell ((erleat-extra-highlight nil))
            (with-current-buffer buffer
              (dolist (mode '(eat-semi-char-mode eat-char-mode))
                (funcall mode)
                (should (eq (key-binding (kbd "C-v")) 'eat-yank))
                (should (eq (key-binding (kbd "C-c C-p")) 'erleat-previous-shell-prompt))
                (should (eq (key-binding (kbd "C-c C-n")) 'erleat-next-shell-prompt))))))
      (cl-mapc (lambda (key binding) (define-key erleat-mode-map (kbd key) binding)) keys old))))

(provide 'erleat-highlight-tests)
;;; erleat-highlight-tests.el ends here
