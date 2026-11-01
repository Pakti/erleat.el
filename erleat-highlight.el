;;; erleat-highlight.el --- Highlight Erlang Eat interactions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-only

;;; Commentary:

;; Enable through `erleat-mode-hook', following the core mode's state:
;; (add-hook 'erleat-mode-hook
;;           (lambda () (erleat-highlight-mode (if erleat-mode 1 -1))))
;; With `erleat-mode' active, RET delegates to Eat's original command and
;; tracks the subsequent rendered output until the next numbered prompt.
;; The last unindented line with its indented continuations is treated as
;; the return value and fontified with Erlang mode.  Earlier output uses
;; `erleat-output'.  This is a heuristic, not an Erlang term parser:
;; prompt-shaped application output and unusual pretty printing can fool it.
;; Read submission state recorded by `erleat-mode'; this module does not
;; bind keys or send terminal input.
;; Use `erleat-font-lock-add-keywords-function' to install custom result font-lock rules
;; without running the source buffer's `erlang-mode-hook'.
;;
;; All highlighting uses overlays; Eat owns the terminal text and input.

;;; Code:

(require 'erlang)

(declare-function eat-term-display-cursor "eat" (terminal))

(defvar eat-terminal)
(defvar erleat-prompt-regexp)
(defvar erleat--input-line)
(defvar erleat--submitted-line)
(defvar erleat--sending)
(declare-function erleat--input-line-beginning "erleat" ())
(declare-function erleat--input-line-end "erleat" ())
(declare-function erleat--forget-input "erleat" (&optional process))
(declare-function eat-term-filter-string "eat" (string))

(defvar erleat-highlight-mode)

(defface erleat-output
  '((t (:inherit default)))
  "Face for expression output preceding the returned value."
  :group 'erleat)

(defface erleat-result
  '((t (:inherit default)))
  "Fallback face for returned values without an Erlang syntax face."
  :group 'erleat)

(defcustom erleat-font-lock-add-keywords-function nil
  "Optional no-argument function installing font-lock rules for results.
Called in the temporary result buffer after activating `erlang-mode',
before `font-lock-ensure'.  Use `font-lock-add-keywords' to install
rules, as in a source buffer.  Nil means no additional setup.
`erlang-mode-hook' and `prog-mode-hook' stay disabled here.
Text-property faces are copied to the Eat terminal; overlay faces are not."
  :type '(choice (const :tag "No additional keywords" nil) function)
  :group 'erleat)

(defvar-local erleat-highlight--results nil
  "Output and result overlays owned by this integration.")

(defun erleat-highlight--result-bounds ()
  "Find the last unindented result and its indented continuation lines.
Operate on the normalized output in the current temporary buffer.
Return (BEGIN . END), or nil for empty or entirely indented output."
  (goto-char (point-max))
  (when (bolp) (forward-line -1))
  (beginning-of-line)
  (while (and (> (point) (point-min)) (looking-at-p "[ \t]*$"))
    (forward-line -1))
  (let ((end (line-end-position)))
    (while (and (> (point) (point-min)) (looking-at-p "[ \t]+\\S-"))
      (forward-line -1))
    (when (looking-at-p "\\S-")
      (cons (point) end))))

(defun erleat-highlight--overlay (begin end face priority)
  "Add an owned overlay from BEGIN to END with FACE and PRIORITY."
  (when (< begin end)
    (let ((overlay (make-overlay begin end)))
      (overlay-put overlay 'face face)
      (overlay-put overlay 'priority priority)
      (overlay-put overlay 'evaporate t)
      (push overlay erleat-highlight--results))))

(defun erleat-highlight--source (begin end)
  "Normalize BEGIN to END, retaining original terminal character positions."
  (let ((text (buffer-substring begin end)))
    ;; Eat's filter edits a temporary string buffer, so remove terminal
    ;; protection first.  Do not alter any properties in the real terminal.
    (remove-text-properties 0 (length text)
                            '(read-only nil field nil front-sticky nil rear-nonsticky nil)
                            text)
    (dotimes (index (length text))
      (put-text-property index (1+ index) 'erleat-origin (+ begin index) text))
    (eat-term-filter-string text)))

(defun erleat-highlight--output (begin end)
  "Highlight output and its final result between BEGIN and END.
Normalize wrapping and wide-character padding before fontification,
retaining each character's original terminal position for overlays."
  (let ((shell (current-buffer))
        (text (erleat-highlight--source begin end)))
    (with-temp-buffer
      (insert text)
      (let ((bounds (erleat-highlight--result-bounds)))
        (if (not bounds)
            (with-current-buffer shell
              (erleat-highlight--overlay begin end 'erleat-output 1))
          (let* ((start (car bounds))
                 (limit (cdr bounds))
                 (result-begin (get-text-property start 'erleat-origin))
                 (result-end (1+ (get-text-property (1- limit) 'erleat-origin))))
            (with-current-buffer shell
              (erleat-highlight--overlay begin result-begin 'erleat-output 1)
              (erleat-highlight--overlay result-begin result-end 'erleat-result 2))
            ;; Fontify in isolation: do not enable the user's source-buffer
            ;; hooks (for example Flymake) in this temporary result buffer.
            (let ((erlang-mode-hook nil) (prog-mode-hook nil))
              (erlang-mode))
            (when erleat-font-lock-add-keywords-function
              (funcall erleat-font-lock-add-keywords-function))
            (font-lock-ensure start limit)
            (let ((position start))
              (while (< position limit)
                (let* ((face (or (get-text-property position 'face)
                                 (get-text-property position 'font-lock-face)))
                       (next (min (next-single-property-change position 'face nil limit)
                                  (next-single-property-change position 'font-lock-face nil limit))))
                  (when face
                    (let ((from (get-text-property position 'erleat-origin))
                          (to (1+ (get-text-property (1- next) 'erleat-origin))))
                      (with-current-buffer shell
                        (erleat-highlight--overlay from to face 3))))
                  (setq position next))))))))))

(defun erleat-highlight--finish ()
  "Highlight a pending evaluation when a clean rendered prompt arrives."
  (when (and eat-terminal erleat--input-line
             (not erleat--sending))
    (save-excursion
      (goto-char (eat-term-display-cursor eat-terminal))
      (let ((prompt (erleat--input-line-beginning)))
        (goto-char prompt)
        (when (and (> prompt erleat--input-line)
                   (looking-at erleat-prompt-regexp)
                   (= (match-end 0) (erleat--input-line-end)))
          ;; Eat can redraw all of a multiline command, collapsing markers
          ;; inside it.  Relocate the echoed final input line in normalized
          ;; text instead of treating a collapsed marker as the output start.
          (let* ((text (erleat-highlight--source
                        erleat--input-line prompt))
                 ;; Erlang can replace its ".. " continuation prompt
                 ;; with indentation when redrawing a completed command.
                 (regexp (concat "^[ \t.]*"
                                 (regexp-quote erleat--submitted-line)
                                 "\n")))
            (when (string-match regexp text)
              (let ((offset (match-end 0)))
                (when (< offset (length text))
                  (erleat-highlight--output
                   (get-text-property offset 'erleat-origin text) prompt)))))
          (erleat--forget-input))))))

(defun erleat-highlight--update (&optional _process)
  "Refresh optional output/result highlighting after terminal output or exit."
  (setq erleat-highlight--results
        (cl-delete-if-not #'overlay-buffer erleat-highlight--results))
  (when eat-terminal
    (erleat-highlight--finish)))

(defun erleat-highlight--cleanup ()
  "Remove only the output and result overlays owned by this module."
  (mapc #'delete-overlay erleat-highlight--results)
  (setq erleat-highlight--results nil))

(define-minor-mode erleat-highlight-mode
  "Highlight expression output and returned values in an Eat shell.
With `erleat-mode' active, RET tracks results using the numbered
prompt and last-unindented-line heuristics described in this library."
  :lighter nil
  (if erleat-highlight-mode
      (progn
        (unless (derived-mode-p 'eat-mode)
          (setq erleat-highlight-mode nil)
          (user-error "Erlang Eat highlighting needs an Eat buffer"))
        (add-hook 'erleat--after-send-input-hook #'erleat-highlight--update nil t)
        (add-hook 'eat-update-hook #'erleat-highlight--update nil t)
        (add-hook 'eat-exit-hook #'erleat-highlight--update nil t)
        (add-hook 'change-major-mode-hook #'erleat-highlight--cleanup nil t)
        (add-hook 'kill-buffer-hook #'erleat-highlight--cleanup nil t)
        (erleat-highlight--update))
    (remove-hook 'erleat--after-send-input-hook #'erleat-highlight--update t)
    (remove-hook 'eat-update-hook #'erleat-highlight--update t)
    (remove-hook 'eat-exit-hook #'erleat-highlight--update t)
    (remove-hook 'change-major-mode-hook #'erleat-highlight--cleanup t)
    (remove-hook 'kill-buffer-hook #'erleat-highlight--cleanup t)
    (erleat-highlight--cleanup)))

(provide 'erleat-highlight)

;;; erleat-highlight.el ends here
