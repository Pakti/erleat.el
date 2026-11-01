;;; erlang-comint-redraw.el --- Filter Erlang input redraws in Comint -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pakti
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Keep the original erlang-shell-mode, including compilation and EUnit
;; integration.  Enable with:
;;
;;   (require 'erlang-comint-redraw)
;;   (add-hook 'erlang-shell-mode-hook #'erlang-comint-redraw-mode)
;;
;; The modern Erlang shell redraws submitted expressions with cursor-up and
;; erase-to-end-of-screen sequences.  Comint already inserted that expression.
;; Discard only redraws which exactly reproduce the submitted expression, using
;; Erlang's default shell formatter.  This is deliberately not a terminal
;; emulator: other terminal operations and custom formatters are not handled.
;; No Eat or Erleat dependency, upstream changes, or command replacements.

;;; Code:

(require 'comint)
(require 'subr-x)
(require 'seq)

(defgroup erlang-comint-redraw nil
  "Filter duplicate Erlang shell input redraws."
  :group 'comint)

(defcustom erlang-comint-redraw-prompt-regexp "^[[:digit:]]+> "
  "Regexp identifying a primary Erlang shell prompt."
  :type 'regexp)

(defcustom erlang-comint-redraw-timeout 0.5
  "Seconds to wait for the rest of a possible redraw before passing it through."
  :type 'number)

(defvar-local erlang-comint-redraw--prompt nil)
(defvar-local erlang-comint-redraw--input nil)
(defvar-local erlang-comint-redraw--expected nil)
(defvar-local erlang-comint-redraw--pending "")
(defvar-local erlang-comint-redraw--timer nil)
(defvar erlang-comint-redraw--flushing nil)

(defun erlang-comint-redraw--record (input)
  "Remember INPUT before Comint sends it to Erlang."
  (let* ((process (get-buffer-process (current-buffer)))
         (prompt (and process
                      (save-excursion
                        (goto-char (process-mark process))
                        (let ((inhibit-field-text-motion t))
                          (buffer-substring-no-properties
                           (line-beginning-position) (point)))))))
    (cond
     ((and prompt (string-match-p
                   (concat erlang-comint-redraw-prompt-regexp "\\'") prompt))
      (setq erlang-comint-redraw--prompt prompt
            erlang-comint-redraw--input input))
     ((and (equal prompt ".. ") erlang-comint-redraw--prompt)
      (setq erlang-comint-redraw--input
            (concat erlang-comint-redraw--input input)))
     (t (setq erlang-comint-redraw--prompt nil
              erlang-comint-redraw--input nil)))
    (setq erlang-comint-redraw--expected
          (when erlang-comint-redraw--prompt
            (let* ((body (string-trim-right erlang-comint-redraw--input "\n+"))
                   (indent (make-string (string-width erlang-comint-redraw--prompt) ?\s))
                   (text (concat erlang-comint-redraw--prompt
                                 (replace-regexp-in-string "\n" (concat "\n" indent)
                                                           body t t)
                                 "\n")))
              (list text (replace-regexp-in-string "\n" "\r\n" text t t)))))))

(defun erlang-comint-redraw--cancel-timer ()
  "Cancel the incomplete-redraw timer."
  (when (timerp erlang-comint-redraw--timer)
    (cancel-timer erlang-comint-redraw--timer))
  (setq erlang-comint-redraw--timer nil))

(defun erlang-comint-redraw--flush (buffer)
  "Pass any incomplete redraw in BUFFER back to Comint unchanged."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (erlang-comint-redraw--cancel-timer)
      (let ((text erlang-comint-redraw--pending)
            (process (get-buffer-process buffer))
            (erlang-comint-redraw--flushing t))
        (setq erlang-comint-redraw--pending "")
        (when (and process (not (string-empty-p text)))
          (comint-output-filter process text))))))

(defun erlang-comint-redraw--filter (output)
  "Remove a verified duplicate input redraw from OUTPUT.
Buffer incomplete candidates across process chunks, with a size and time bound.
Unknown sequences and nonmatching text are passed through unchanged."
  (if erlang-comint-redraw--flushing output
    (erlang-comint-redraw--cancel-timer)
    (let ((text (concat erlang-comint-redraw--pending output))
          (start 0) pieces done)
      (setq erlang-comint-redraw--pending "")
      (while (and (not done) (string-match "\e" text start))
        (let* ((escape (match-beginning 0))
               (tail (substring text escape))
               (prefix (and erlang-comint-redraw--expected
                            (string-match
                             "\\`\\(?:\e\\[[0-9]*A\\)+\e\\[0?J" tail)
                            (match-end 0)))
               (payload (and prefix (substring tail prefix)))
               (expected (and prefix
                              (seq-find (lambda (s) (string-prefix-p s payload))
                                        erlang-comint-redraw--expected)))
               (partial
                (and erlang-comint-redraw--expected
                     (< (length tail) 65536)
                     (if prefix
                         (seq-some (lambda (s) (string-prefix-p payload s))
                                   erlang-comint-redraw--expected)
                       (and (< (length tail) 256)
                            (string-match-p
                             "\\`\\(?:\e\\[[0-9]*A\\)*\\(?:\e\\(?:\\[[0-9]*\\)?\\)?\\'"
                             tail))))))
          (push (substring text start escape) pieces)
          (cond
           (expected
            (setq start (+ escape prefix (length expected))
                  erlang-comint-redraw--expected nil))
           (partial
            (setq erlang-comint-redraw--pending tail
                  start (length text) done t))
           (t (push "\e" pieces) (setq start (1+ escape))))))
      (push (substring text start) pieces)
      (unless (string-empty-p erlang-comint-redraw--pending)
        (setq erlang-comint-redraw--timer
              (run-at-time erlang-comint-redraw-timeout nil
                           #'erlang-comint-redraw--flush (current-buffer))))
      (apply #'concat (nreverse pieces)))))

;;;###autoload
(define-minor-mode erlang-comint-redraw-mode
  "Suppress verified duplicate Erlang expression redraws in this Comint buffer.
Enable before sending input.  Keep `comint-process-echoes' enabled as usual.
This handles the default formatter's submitted-input redraw, not arbitrary
terminal editing, custom formatters, or full-screen applications."
  :lighter " ErlRedraw"
  (if erlang-comint-redraw-mode
      (progn
        (unless (derived-mode-p 'comint-mode)
          (setq erlang-comint-redraw-mode nil)
          (user-error "This filter needs a Comint buffer"))
        (add-hook 'comint-input-filter-functions #'erlang-comint-redraw--record nil t)
        (add-hook 'comint-preoutput-filter-functions #'erlang-comint-redraw--filter nil t)
        (add-hook 'kill-buffer-hook #'erlang-comint-redraw--cancel-timer nil t))
    (remove-hook 'comint-preoutput-filter-functions #'erlang-comint-redraw--filter t)
    (remove-hook 'comint-input-filter-functions #'erlang-comint-redraw--record t)
    (remove-hook 'kill-buffer-hook #'erlang-comint-redraw--cancel-timer t)
    (erlang-comint-redraw--flush (current-buffer))
    (setq erlang-comint-redraw--prompt nil
          erlang-comint-redraw--input nil
          erlang-comint-redraw--expected nil)))

(provide 'erlang-comint-redraw)
;;; erlang-comint-redraw.el ends here
