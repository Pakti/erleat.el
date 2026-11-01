;;; erlang-shell-highlight.el --- Highlight Erlang Comint results -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Optional output/result highlighting for the original erlang-shell-mode:
;;   (require 'erlang-shell-highlight)
;;   (add-hook 'erlang-shell-mode-hook #'erlang-shell-highlight-mode)
;; Works with erlang-comint-redraw-mode or with the old Erlang shell.
;; The final unindented line and its indented continuations are treated as
;; the returned value.  Earlier text is printed output.  This is a heuristic:
;; prompt-shaped output and unusual pretty printing can fool it.
;; No key bindings are replaced.  Advice tracks Comint submissions only in
;; buffers with this mode enabled, including upstream compilation commands.

;;; Code:

(require 'comint)
(require 'erlang)
(require 'cl-lib)

(defgroup erlang-shell-highlight nil
  "Optional highlighting of Erlang shell output and results."
  :group 'erlang)

(defface erlang-shell-highlight-output
  '((t (:inherit default)))
  "Face for printed output preceding the returned value."
  :group 'erlang-shell-highlight)

(defface erlang-shell-highlight-result
  '((t (:inherit default)))
  "Fallback face for returned values without an Erlang syntax face."
  :group 'erlang-shell-highlight)

(defcustom erlang-shell-highlight-font-lock-add-keywords-function nil
  "Optional no-argument function installing result font-lock rules.
Called in a temporary `erlang-mode' buffer before `font-lock-ensure'.
Use `font-lock-add-keywords' as in a source buffer.  For efficiency,
`erlang-mode-hook' and `prog-mode-hook' are suppressed there.  Font lock
itself is enabled; text-property faces are copied, overlay faces are not."
  :type '(choice (const :tag "No additional keywords" nil) function)
  :group 'erlang-shell-highlight)

(defvar erlang-shell-highlight-mode)
(defvar-local erlang-shell-highlight--start nil
  "Borrowed Comint input-end marker; never move or detach it here.")
(defvar-local erlang-shell-highlight--sending nil)
(defvar-local erlang-shell-highlight--overlays nil)

(defun erlang-shell-highlight--bounds (begin end)
  "Find the final result between BEGIN and END, returning bounds or nil."
  (save-excursion
    (goto-char end)
    (when (bolp) (forward-line -1))
    (beginning-of-line)
    (while (and (> (point) begin) (looking-at-p "[ \t]*$"))
      (forward-line -1))
    (let ((limit (line-end-position)))
      (while (and (> (point) begin) (looking-at-p "[ \t]+\\S-"))
        (forward-line -1))
      (when (and (>= (point) begin) (< (point) limit)
                 (looking-at-p "\\S-"))
        (cons (point) limit)))))

(defun erlang-shell-highlight--overlay (begin end face priority)
  "Add an owned overlay from BEGIN to END with FACE and PRIORITY."
  (when (< begin end)
    (let ((overlay (make-overlay begin end)))
      (overlay-put overlay 'face face)
      (overlay-put overlay 'priority priority)
      (overlay-put overlay 'evaporate t)
      (push overlay erlang-shell-highlight--overlays))))

(defun erlang-shell-highlight--result (begin end)
  "Syntax-highlight the returned Erlang term between BEGIN and END."
  (erlang-shell-highlight--overlay begin end 'erlang-shell-highlight-result 2)
  (let ((shell (current-buffer))
        (text (buffer-substring-no-properties begin end)))
    (with-temp-buffer
      (insert text)
      (let ((erlang-mode-hook nil) (prog-mode-hook nil))
        (erlang-mode))
      (when erlang-shell-highlight-font-lock-add-keywords-function
        (funcall erlang-shell-highlight-font-lock-add-keywords-function))
      (font-lock-ensure (point-min) (point-max))
      (let ((position (point-min)) (limit (point-max)))
        (while (< position limit)
          (let* ((face (or (get-text-property position 'face)
                           (get-text-property position 'font-lock-face)))
                 (next (min (next-single-property-change position 'face nil limit)
                            (next-single-property-change position 'font-lock-face nil limit))))
            (when face
              (with-current-buffer shell
                (erlang-shell-highlight--overlay
                 (+ begin (1- position)) (+ begin (1- next)) face 3)))
            (setq position next)))))))

(defun erlang-shell-highlight--finish (&optional _output)
  "Highlight a pending evaluation once a complete prompt has arrived."
  (setq erlang-shell-highlight--overlays
        (cl-delete-if-not #'overlay-buffer erlang-shell-highlight--overlays))
  (when (and erlang-shell-highlight-mode erlang-shell-highlight--start
             (marker-position erlang-shell-highlight--start)
             (not erlang-shell-highlight--sending))
    (let ((process (get-buffer-process (current-buffer)))
          (inhibit-field-text-motion t))
      (when process
        (save-restriction
          ;; Unsent local input, including leading spaces, is not part of
          ;; the process's prompt and must not influence its recognition.
          (narrow-to-region (point-min) (process-mark process))
          (save-excursion
            (goto-char (process-mark process))
            (beginning-of-line)
            (when (and (> (point) erlang-shell-highlight--start)
                       (looking-at comint-prompt-regexp)
                       (= (match-end 0) (process-mark process)))
              (let* ((begin (marker-position erlang-shell-highlight--start))
                     (end (point))
                     (bounds (erlang-shell-highlight--bounds begin end)))
                (if bounds
                    (progn
                      (erlang-shell-highlight--overlay
                       begin (car bounds) 'erlang-shell-highlight-output 1)
                      (erlang-shell-highlight--result (car bounds) (cdr bounds)))
                  (erlang-shell-highlight--overlay
                   begin end 'erlang-shell-highlight-output 1)))
              (setq erlang-shell-highlight--start nil))))))))

(defun erlang-shell-highlight--record (_input)
  "Track Comint's input-end marker, which is updated before sending input."
  (setq erlang-shell-highlight--start comint-last-input-end))

(defun erlang-shell-highlight--send (original &rest arguments)
  "Call ORIGINAL with ARGUMENTS, deferring highlighting until sending finishes."
  (if (not erlang-shell-highlight-mode)
      (apply original arguments)
    (unwind-protect
        (let ((erlang-shell-highlight--sending t))
          (apply original arguments))
      (erlang-shell-highlight--finish))))

(defun erlang-shell-highlight--cleanup ()
  "Remove owned overlays and forget the borrowed input marker."
  (mapc #'delete-overlay erlang-shell-highlight--overlays)
  (setq erlang-shell-highlight--overlays nil
        erlang-shell-highlight--start nil))

;;;###autoload
(define-minor-mode erlang-shell-highlight-mode
  "Highlight printed output and returned terms in an Erlang Comint shell.
Use the last-unindented-line heuristic to distinguish returned values.
Prompt and submitted-input highlighting remain owned by Erlang mode/Comint."
  :lighter " ErlHL"
  (if erlang-shell-highlight-mode
      (progn
        (unless (derived-mode-p 'erlang-shell-mode)
          (setq erlang-shell-highlight-mode nil)
          (user-error "Highlighting needs an Erlang shell buffer"))
        (add-hook 'comint-input-filter-functions #'erlang-shell-highlight--record nil t)
        ;; Append: upstream backspace/CR cleanup must finish first.
        (add-hook 'comint-output-filter-functions #'erlang-shell-highlight--finish t t)
        (add-hook 'change-major-mode-hook #'erlang-shell-highlight--cleanup nil t)
        (add-hook 'kill-buffer-hook #'erlang-shell-highlight--cleanup nil t))
    (remove-hook 'comint-input-filter-functions #'erlang-shell-highlight--record t)
    (remove-hook 'comint-output-filter-functions #'erlang-shell-highlight--finish t)
    (remove-hook 'change-major-mode-hook #'erlang-shell-highlight--cleanup t)
    (remove-hook 'kill-buffer-hook #'erlang-shell-highlight--cleanup t)
    (erlang-shell-highlight--cleanup)))

;; Preserve RET's upstream compilation-error navigation and every existing
;; command that submits through Comint.  Outside enabled buffers this advice
;; delegates directly and leaves Comint's behavior unchanged.
(unless (advice-member-p #'erlang-shell-highlight--send 'comint-send-input)
  (advice-add 'comint-send-input :around #'erlang-shell-highlight--send))

(provide 'erlang-shell-highlight)
;;; erlang-shell-highlight.el ends here
