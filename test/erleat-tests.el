;;; erleat-tests.el --- Prompt navigation and shell tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-only

;;; Code:

(require 'erleat-test-helper)

(defvar-local erleat-test--legacy-maps nil
  "Temporary stale keymaps used by the RET reload regression test.")

(defmacro erleat-test--transcript (&rest body)
  `(with-temp-buffer
     (insert "Eshell\n1> first.\nresult\n2> second.\nresult\n3> ")
     (let ((ends (save-excursion
                   (goto-char (point-min))
                   (let (found)
                     (while (re-search-forward erleat-prompt-regexp nil t)
                       (push (match-end 0) found))
                     (nreverse found)))))
       ,@body)))

(ert-deftest erleat-test-prompt-end-repeated-navigation ()
  (erleat-test--transcript
    (goto-char (point-min))
    (dolist (end ends)
      (erleat-next-shell-prompt)
      (should (= (point) end)))
    (erleat-previous-shell-prompt)
    (should (= (point) (nth 1 ends)))
    (erleat-previous-shell-prompt)
    (should (= (point) (nth 0 ends)))))

(ert-deftest erleat-test-prompt-end-from-prefix-and-input ()
  (erleat-test--transcript
    (goto-char (- (nth 1 ends) 2))
    (erleat-next-shell-prompt)
    (should (= (point) (nth 1 ends)))
    (goto-char (- (nth 1 ends) 2))
    (erleat-previous-shell-prompt)
    (should (= (point) (nth 0 ends)))
    (goto-char (+ (nth 1 ends) 2))
    (erleat-previous-shell-prompt)
    (should (= (point) (nth 1 ends)))
    (goto-char (+ (nth 1 ends) 2))
    (erleat-next-shell-prompt)
    (should (= (point) (nth 2 ends)))))

(ert-deftest erleat-test-prompt-end-counts-and-failed-searches ()
  (erleat-test--transcript
    (goto-char (nth 0 ends))
    (erleat-next-shell-prompt 2)
    (should (= (point) (nth 2 ends)))
    (should-error (erleat-next-shell-prompt) :type 'user-error)
    (should (= (point) (nth 2 ends)))
    (should-error (erleat-previous-shell-prompt 3) :type 'user-error)
    (should (= (point) (nth 2 ends)))
    (erleat-next-shell-prompt -2)
    (should (= (point) (nth 0 ends)))
    (erleat-previous-shell-prompt -2)
    (should (= (point) (nth 2 ends)))
    (erleat-next-shell-prompt 0)
    (should (= (point) (nth 2 ends)))))

(ert-deftest erleat-test-prompt-end-custom-read-only-and-empty ()
  (with-temp-buffer
    (let ((erleat-prompt-regexp "^\\[[[:digit:]]+\\]> "))
      (insert "[1]> first\n[2]> ")
      (add-text-properties (point-min) (point-max) '(field eat-terminal read-only t))
      (goto-char (point-min))
      (erleat-next-shell-prompt)
      (should (looking-at "first"))
      (erleat-next-shell-prompt)
      (should (eobp))
      (erleat-previous-shell-prompt)
      (should (looking-at "first"))
      (narrow-to-region (point) (point-max))
      (should-error (erleat-previous-shell-prompt) :type 'user-error)))
  (with-temp-buffer
    (should-error (erleat-next-shell-prompt) :type 'user-error)
    (should-error (erleat-previous-shell-prompt) :type 'user-error)))

(defun erleat-test--faces-at-text (text offset)
  "Return overlay faces OFFSET characters into the first occurrence of TEXT."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (mapcar (lambda (overlay) (overlay-get overlay 'face))
            (overlays-at (+ (- (point) (length text)) offset)))))

(ert-deftest erleat-test-prompt-highlight-01-prompt-input-and-output ()
  (erleat-test-with-shell nil
    (with-current-buffer buffer
      (should (memq 'erleat-prompt (erleat-test--faces-at-text "1> " 0))))
    (erleat-test--command buffer "1+2.")
    (with-current-buffer buffer
      (should (memq 'erleat-input (erleat-test--faces-at-text "1+2." 0)))
      (should (memq 'erleat-prompt (erleat-test--faces-at-text "2> " 0)))
      (should-not (memq 'erleat-input (erleat-test--faces-at-text "\n3\n" 1)))
      (should (equal (face-attribute 'erleat-prompt :inherit) 'comint-highlight-prompt))
      (should (equal (face-attribute 'erleat-input :inherit) 'comint-highlight-input)))))

(ert-deftest erleat-test-prompt-highlight-02-pending-input-and-editing ()
  (erleat-test-with-shell nil
    (erleat-test--send buffer "4+3.")
    (erleat-test--wait buffer (lambda () (string-match-p (regexp-quote "4+3.") (erleat-test--cursor-line))))
    (with-current-buffer buffer
      (should-not (memq 'erleat-input (erleat-test--faces-at-text "4+3." 0))))
    (erleat-test--send buffer "\e[D\e[D\C-d2\C-e\r")
    (erleat-test--wait buffer (lambda () (equal (erleat-test--prompt-number) 2)))
    (with-current-buffer buffer
      (should (memq 'erleat-input (erleat-test--faces-at-text "4+2." 0)))
      (should-not (string-match-p (regexp-quote "4+3.") (buffer-string))))))

(ert-deftest erleat-test-prompt-highlight-03-wrapped-input-and-unicode ()
  (erleat-test-with-shell nil
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (eat-term-resize eat-terminal 40 24))
      (set-process-window-size (get-buffer-process buffer) 24 40))
    (let ((command (format "io:format(\"%sTAIL~ts~n\", [[955,38634]])." (make-string 90 ?x))))
      (should (string-match-p "TAILλ雪" (erleat-test--command buffer command)))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (search-forward "io:format")
          (let ((overlay (cl-find-if
                          (lambda (o) (eq (overlay-get o 'face) 'erleat-input))
                          (overlays-at (1- (point))))))
            (should overlay)
            (should (equal command (filter-buffer-substring
                                    (overlay-start overlay) (overlay-end overlay))))))))))

(ert-deftest erleat-test-prompt-highlight-04-nondestructive-and-bounded-overlays ()
  (erleat-test-with-shell nil
    (erleat-test--command buffer "io:format(\"~c[31mRED~c[0m~n\", [27,27]).")
    (with-current-buffer buffer
      (let* ((text (buffer-string))
             (count (length erleat--highlight-overlays))
             (foreign (make-overlay (point-min) (1+ (point-min)))))
        (unwind-protect
            (progn
              (set-buffer-modified-p nil)
              (dotimes (_ 10) (erleat--highlight))
              (should (equal-including-properties text (buffer-string)))
              (should-not (buffer-modified-p))
              (should (= count (length erleat--highlight-overlays)))
              (should (overlay-buffer foreign))
              (should-not (memq 'erleat-input (erleat-test--faces-at-text "\nRED\n" 1))))
          (delete-overlay foreign))))))


(ert-deftest erleat-test-core-keymap-precedence-and-disable ()
  (erleat-test-with-shell nil
    (let ((old (lookup-key erleat-mode-map (kbd "C-a"))))
      (unwind-protect
          (progn
            (define-key erleat-mode-map (kbd "C-a") #'beginning-of-line)
            (with-current-buffer buffer
              (dolist (input-mode '(eat-semi-char-mode eat-char-mode eat-line-mode))
                (funcall input-mode)
                (should (eq (key-binding (kbd "C-a")) 'beginning-of-line))
                (should (eq (key-binding (kbd "RET")) 'erleat-send-input)))
              (eat-semi-char-mode)
              (erleat-mode -1)
              (should (eq (key-binding (kbd "RET")) 'eat-self-input))
              (should (eq (key-binding (kbd "C-a")) 'eat-self-input))
              (should-not erleat--highlight-overlays)
              (should-not erleat--input-line)
              (erleat-mode 1)
              (should (eq (key-binding (kbd "C-a")) 'beginning-of-line))))
        (define-key erleat-mode-map (kbd "C-a") old)))))

(ert-deftest erleat-test-mode-hook-and-buffer-identity-lifecycle ()
  (let ((enables 0) (disables 0))
    (erleat-test-with-shell
        ((erleat-mode-hook
          (list (lambda ()
                  (should erleat-buffer-p)
                  (if erleat-mode (setq enables (1+ enables))
                    (setq disables (1+ disables)))))))
      (should (= enables 1))
      (should (local-variable-p 'erleat-buffer-p buffer))
      (should (buffer-local-value 'erleat-buffer-p buffer))
      (erleat)
      (should (= enables 1))
      (with-current-buffer buffer
        (erleat-mode -1)
        (should (= disables 1))
        (erleat-mode 1)
        (should (= enables 2)))
      (let ((process (get-buffer-process buffer)))
        (erleat-test--send buffer "q().\r")
        (erleat-test--wait buffer (lambda () (not (process-live-p process)))))
      (should (buffer-local-value 'erleat-buffer-p buffer))
      (erleat)
      (erleat-test--wait buffer (lambda () (erleat-test--prompt-number)))
      (should (= enables 3))
      (with-temp-buffer
        (eat-mode)
        (should-not erleat-mode)
        (should-not erleat-buffer-p)))))

(ert-deftest erleat-test-ret-bypasses-stale-highlighting-keymap ()
  (erleat-test-with-shell ((erleat-extra-highlight t))
    (let ((legacy-calls 0)
          (legacy-map (make-sparse-keymap)))
      (define-key legacy-map (kbd "RET") 'erleat-highlight-send-input)
      (with-current-buffer buffer
        (setq erleat-test--legacy-maps `((erleat-highlight-mode . ,legacy-map)))
        (setq-local emulation-mode-map-alists
                    (append emulation-mode-map-alists '(erleat-test--legacy-maps)))
        ;; This is the stale binding that used to cause mutual recursion.
        (should (eq (let ((erleat-mode nil)) (key-binding (kbd "RET")))
                    'erleat-highlight-send-input)))
      (cl-letf (((symbol-function 'erleat-highlight-send-input)
                 (lambda ()
                   (interactive)
                   (setq legacy-calls (1+ legacy-calls))
                   (error "Stale RET handler would recurse"))))
        (erleat-test--submit buffer "6+7.")
        (erleat-test--complete buffer 2)
        (should (= legacy-calls 0))
        (should (equal (erleat-test--regions buffer 'erleat-result) '("13")))))))

(ert-deftest erleat-test-loader-reloads-only-local-source ()
  (let* ((directory (make-temp-file "erleat-loader-test-" t))
         (load-path (copy-sequence load-path))
         (original (symbol-function 'erlang-version))
         (sentinel (lambda () 'upstream-not-reloaded)))
    (unwind-protect
        (progn
          (dolist (file '("erleat.el" "erleat-highlight.el" "erleat-load-all.el"))
            (copy-file (expand-file-name file erleat-test-root)
                       (expand-file-name file directory))
            (with-temp-file (expand-file-name (concat (file-name-base file) ".elc") directory)
              (insert "(error \"Stale compiled file loaded\")\n")))
          (fset 'erlang-version sentinel)
          (load (expand-file-name "erleat-load-all.el" directory) nil t t)
          (let* ((stub (lambda () 'old-definition))
                 (erleat-font-lock-add-keywords-function #'ignore))
            (fset 'erleat stub)
            (load (expand-file-name "erleat-load-all.el" directory) nil t t)
            (should-not (eq stub (symbol-function 'erleat)))
            (should (equal (symbol-file 'erleat) (expand-file-name "erleat.el" directory)))
            (should (eq erleat-font-lock-add-keywords-function #'ignore)))
          (should (eq sentinel (symbol-function 'erlang-version))))
      (fset 'erlang-version original)
      (load (expand-file-name "erleat-highlight.el" erleat-test-root) nil t t)
      (load (expand-file-name "erleat.el" erleat-test-root) nil t t)
      (delete-directory directory t))))

(provide 'erleat-tests)
;;; erleat-tests.el ends here
