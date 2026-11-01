;;; erleat-test-helper.el --- Fixtures for Erleat tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-only

;;; Code:

(require 'cl-lib)
(require 'ert)

(defconst erleat-test-root
  (file-name-directory
   (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "Root of the checkout under test.")

(add-to-list 'load-path erleat-test-root)
(require 'erleat)
(require 'eat)

(defun erleat-test--wait (buffer predicate &optional timeout)
  "Wait up to TIMEOUT seconds for PREDICATE to succeed in BUFFER."
  (let ((deadline (+ (float-time) (or timeout 10))) result)
    (while (and (not (setq result
                           (with-current-buffer buffer
                             (let ((inhibit-field-text-motion t))
                               (funcall predicate)))))
                (< (float-time) deadline))
      (accept-process-output nil 0.03))
    (unless result
      (error "Timed out waiting for Erlang; terminal: %s"
             (with-current-buffer buffer
               (filter-buffer-substring (max (point-min) (- (point-max) 4000))
                                        (point-max)))))
    result))

(defun erleat-test--cursor-line ()
  "Return the normalized logical line containing the terminal cursor."
  (save-excursion
    (goto-char (eat-term-display-cursor eat-terminal))
    (filter-buffer-substring (erleat--input-line-beginning)
                             (erleat--input-line-end))))

(defun erleat-test--prompt-number ()
  "Return the numbered prompt at the terminal cursor, or nil."
  (let ((line (erleat-test--cursor-line)))
    (when (string-match "\\`\\([0-9]+\\)> *\\'" line)
      (string-to-number (match-string 1 line)))))

(defun erleat-test--send (buffer text)
  "Send TEXT through BUFFER's Eat terminal input API."
  (with-current-buffer buffer (eat-term-send-string eat-terminal text)))

(defun erleat-test--submit (buffer text &optional event)
  "Type TEXT, wait for its echo, then invoke the actual RET binding.
Use EVENT to exercise the GUI return event as well as carriage return."
  (erleat-test--send buffer text)
  (erleat-test--wait buffer
                     (lambda () (string-suffix-p text (erleat-test--cursor-line))))
  (with-current-buffer buffer
    (let ((last-command-event (or event ?\r))
          (current-prefix-arg nil))
      (call-interactively (key-binding (if event [return] (kbd "RET")))))))

(defun erleat-test--complete (buffer number)
  "Wait for prompt NUMBER and completion of result highlighting in BUFFER."
  (erleat-test--wait buffer
                     (lambda () (and (equal (erleat-test--prompt-number) number)
                                     (not erleat--input-line)))))

(defun erleat-test--command (buffer command)
  "Submit COMMAND at a clean prompt and return its rendered transcript."
  (let* ((before (with-current-buffer buffer (erleat-test--prompt-number)))
         (start (with-current-buffer buffer
                  (copy-marker (eat-term-display-cursor eat-terminal)))))
    (unless before (error "Shell is busy or has unfinished input"))
    (unwind-protect
        (progn
          (erleat-test--submit buffer command)
          (erleat-test--wait buffer
                             (lambda ()
                               (let ((number (erleat-test--prompt-number)))
                                 (and number (> number before)))))
          (with-current-buffer buffer
            (filter-buffer-substring start (eat-term-display-cursor eat-terminal))))
      (set-marker start nil))))

(defun erleat-test--regions (buffer face)
  "Return normalized text of result overlays using FACE in BUFFER."
  (with-current-buffer buffer
    (mapcar (lambda (overlay)
              (filter-buffer-substring (overlay-start overlay) (overlay-end overlay)))
            (cl-remove-if-not (lambda (overlay) (eq (overlay-get overlay 'face) face))
                              erleat-highlight--results))))

(defun erleat-test--stop (buffer)
  "Stop and kill the test-owned BUFFER, if it is still alive."
  (when (buffer-live-p buffer)
    (when-let ((process (get-buffer-process buffer)))
      (set-process-query-on-exit-flag process nil)
      (delete-process process))
    (kill-buffer buffer)))

(defmacro erleat-test-with-shell (bindings &rest body)
  "Run BODY with a real test shell named BUFFER and additional BINDINGS.
Use a temporary working directory and preserve any preexisting user shell."
  (declare (indent 1) (debug (sexp body)))
  `(save-window-excursion
     (when (get-buffer "*erlang-eat*")
       (error "Close *erlang-eat* before running integration tests"))
     (let* ((inferior-erlang-machine
             (or (executable-find (or (getenv "ERLEAT_TEST_ERL") "erl"))
                 (error "Erlang runtime not found; put erl on PATH or set ERLEAT_TEST_ERL")))
            (erleat-test--directory (make-temp-file "erleat-test-" t))
            (default-directory (file-name-as-directory erleat-test--directory))
            (inferior-erlang-machine-options
             '("+S" "2:2" "-no_dot_erlang" "-kernel" "shell_history" "disabled"))
            (erlang-inferior-shell-split-window nil)
            (erleat-mode-hook nil)
            (erleat-extra-highlight nil)
            (eat-query-before-killing-running-terminal nil)
            (eat-kill-buffer-on-exit nil)
            buffer)
       (unwind-protect
           (let* ,bindings
             (setq buffer (erleat))
             (erleat-test--wait buffer (lambda () (erleat-test--prompt-number)))
             ,@body)
         (erleat-test--stop (or buffer (get-buffer "*erlang-eat*")))
         (delete-directory erleat-test--directory t)))))

(provide 'erleat-test-helper)
;;; erleat-test-helper.el ends here
