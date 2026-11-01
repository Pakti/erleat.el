;;; erleat.el --- Run the Erlang shell in Eat -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-only
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (eat "0.9.4"))

;;; Commentary:

;; Install Eat, put this directory on `load-path', and
;; load this library:
;;
;;   (require 'erleat)
;;
;; Run M-x erleat to start or display an Erlang terminal.  The command
;; uses `inferior-erlang-machine', `inferior-erlang-machine-options', and
;; `erlang-inferior-shell-split-window' from the existing Erlang mode.
;; Eat handles terminal input and prompt redraws; no Comint input or
;; output filters are installed.  Eat is loaded only when starting a shell.
;; Prompts and submitted input are highlighted automatically.
;; To enable optional output and result highlighting:
;;
;;   (add-hook 'erleat-mode-hook
;;             (lambda () (erleat-highlight-mode (if erleat-mode 1 -1))))
;;
;; Prompt and submitted-input faces inherit the corresponding Comint faces.
;; Highlighting uses overlays after Eat renders output, without modifying
;; the terminal text.  `erleat-highlight' wraps RET to distinguish
;; printed output from the returned value, using the next prompt.
;;
;; This initial integration provides a terminal only.  The existing Erlang
;; shell, compile, and EUnit commands retain their original Comint behavior.
;; In particular, do not select this command as `erlang-shell-function'
;; expecting those commands to use the Eat terminal as well.

;;; Code:

(require 'erlang)

(declare-function eat-make "eat" (name program &optional startfile &rest switches))
(declare-function eat-term-display-cursor "eat" (terminal))
(defvar eat-terminal)

(defgroup erleat nil
  "Erlang shells in Eat terminals."
  :group 'erlang)

(defface erleat-prompt
  '((t (:inherit comint-highlight-prompt)))
  "Face for Erlang prompts in Eat."
  :group 'erleat)

(defface erleat-input
  '((t (:inherit comint-highlight-input)))
  "Face for submitted Erlang input in Eat."
  :group 'erleat)

(defcustom erleat-prompt-regexp "^[[:digit:]]+> "
  "Regexp matching the prompt prefix in rendered terminal lines.
The default recognizes local numbered Erlang prompts.  Output that
resembles a prompt can also match this heuristic."
  :type 'regexp
  :group 'erleat)

(defun erleat--move-shell-prompt (count)
  "Move to COUNT prompts ahead, or backward when COUNT is negative.
Use `erleat-prompt-regexp' within the accessible part of the buffer.
Leave point unchanged if there are not enough matching prompts."
  (let ((backward (< count 0))
        (inhibit-field-text-motion t))
    (goto-char
     (save-excursion
       (save-match-data
         (dotimes (_ (abs count))
           (let ((origin (point)) found)
             (if backward
                 (progn
                   ;; Skip a prompt whose end is already at point.
                   (while (and (setq found (re-search-backward erleat-prompt-regexp nil t))
                               (>= (match-end 0) origin)))
                   (unless found
                     (user-error "No previous Erlang prompt")))
               ;; Include the current prompt if point is inside its prefix.
               (beginning-of-line)
               (while (and (setq found (re-search-forward erleat-prompt-regexp nil t))
                           (<= (match-end 0) origin)))
               (unless found
                 (user-error "No next Erlang prompt")))
             (goto-char (match-end 0))))
         (point))))))

;;;###autoload
(defun erleat-previous-shell-prompt (&optional count)
  "Move to the end of the previous Erlang prompt, before its user input.
With a numeric prefix, move COUNT prompts; negative COUNT moves forward.
Skip a prompt ending exactly at point.
Use `erleat-prompt-regexp'; prompt-shaped output can also match."
  (interactive "p")
  (erleat--move-shell-prompt (- (or count 1))))

;;;###autoload
(defun erleat-next-shell-prompt (&optional count)
  "Move to the end of the next Erlang prompt, before its user input.
With a numeric prefix, move COUNT prompts; negative COUNT moves backward.
Skip a prompt ending exactly at point.  Use `erleat-prompt-regexp';
prompt-shaped output can also match."
  (interactive "p")
  (erleat--move-shell-prompt (or count 1)))

(defvar-local erleat--highlight-overlays nil
  "Overlays owned by Erlang Eat highlighting in this buffer.")

(defun erleat--clear-highlights ()
  "Remove only the overlays owned by Erlang Eat highlighting."
  (mapc #'delete-overlay erleat--highlight-overlays)
  (setq erleat--highlight-overlays nil))

(defun erleat--highlight-region (begin end face)
  "Highlight BEGIN through END with FACE without changing terminal text."
  (when (< begin end)
    (let ((overlay (make-overlay begin end)))
      (overlay-put overlay 'face face)
      (overlay-put overlay 'evaporate t)
      (push overlay erleat--highlight-overlays))))

(defun erleat--highlight (&optional _process)
  "Refresh prompt and submitted-input overlays after Eat renders output.
Also accept the process argument supplied by `eat-exit-hook'.
Input on a numbered prompt's logical line is considered submitted
once the terminal cursor has moved beyond that line.  Continuation
lines of multiline expressions are not inferred from shell output."
  (save-excursion
    (save-restriction
      (widen)
      (erleat--clear-highlights)
      (let ((cursor (if eat-terminal
                        (eat-term-display-cursor eat-terminal)
                      (point-max))))
        (goto-char (point-min))
        (while (re-search-forward erleat-prompt-regexp nil t)
          (let ((begin (match-beginning 0))
                (input (match-end 0))
                (end (line-end-position)))
            ;; Eat's substring filter removes soft-wrap newlines.  Follow
            ;; those wraps without depending on private text properties.
            (while (and (< end (point-max))
                        (equal (filter-buffer-substring end (1+ end)) ""))
              (goto-char (1+ end))
              (setq end (line-end-position)))
            (erleat--highlight-region begin input 'erleat-prompt)
            (when (< end cursor)
              (erleat--highlight-region input end 'erleat-input))
            (goto-char end)))))))

(defvar-local erleat--input-line nil
  "Marker at the logical line most recently submitted through RET.")

(defvar-local erleat--sending nil
  "Non-nil while the original Eat RET command is executing.")

(defvar-local erleat--submitted-line nil
  "Normalized text of the last line submitted through RET.")

(defun erleat--input-line-beginning ()
  "Return the logical line beginning, following Eat's soft wraps."
  (let ((inhibit-field-text-motion t))
    (save-excursion
      (beginning-of-line)
      (while (and (> (point) (point-min))
                  (equal (filter-buffer-substring (1- (point)) (point)) ""))
        (backward-char)
        (beginning-of-line))
      (point))))

(defun erleat--input-line-end ()
  "Return the logical line end, following Eat's soft wraps."
  (let ((inhibit-field-text-motion t))
    (save-excursion
      (end-of-line)
      (while (and (< (point) (point-max))
                  (equal (filter-buffer-substring (point) (1+ (point))) ""))
        (forward-char)
        (end-of-line))
      (point))))

(defun erleat--forget-input (&optional _process)
  "Detach our pending marker, without changing any Eat-owned marker."
  (when erleat--input-line
    (set-marker erleat--input-line nil)
    (setq erleat--input-line nil))
  (setq erleat--submitted-line nil))

(require 'erleat-highlight)

(defvar erleat-mode nil)

(defvar-local erleat--after-send-input-hook nil
  "Internal hook notifying observers after Eat's RET command completes.")

(defun erleat-send-input ()
  "Send input through Eat and record its boundary for output observers.
Optional highlighting observes this state; it does not handle submission."
  (interactive)
  (let* ((key (if (eq last-command-event 'return) [return] (kbd "RET")))
         ;; Reloading does not remove the old highlighting mode's keymaps.
         ;; Exclude both generations of Erleat bindings during lookup so
         ;; the legacy sender cannot delegate straight back to this one.
         (command (let ((erleat-mode nil) (erleat-highlight-mode nil))
                    (or (key-binding key) (key-binding (kbd "RET")))))
         (last-command-event (if (eq last-command-event 'return) 'return ?\r)))
    (unless (and (commandp command)
                 (not (memq command '(erleat-send-input erleat-highlight-send-input))))
      (user-error "Cannot find the original Eat RET command"))
    (when (and eat-terminal (memq command '(eat-self-input eat-line-send-input)))
      (save-excursion
        (goto-char (eat-term-display-cursor eat-terminal))
        (goto-char (erleat--input-line-beginning))
        (when (or erleat--input-line
                  (looking-at erleat-prompt-regexp))
          (erleat--forget-input)
          (setq erleat--input-line (copy-marker (point))
                erleat--submitted-line
                (filter-buffer-substring (point) (erleat--input-line-end)))
          (when (string-prefix-p ".. " erleat--submitted-line)
            (setq erleat--submitted-line
                  (substring erleat--submitted-line 3))))))
    (let ((erleat--sending t))
      (call-interactively command))
    ;; Eat may render output synchronously while sending input.
    (run-hooks 'erleat--after-send-input-hook)))

(defvar erleat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'erleat-send-input)
    (define-key map [return] #'erleat-send-input)
    map)
  "Erleat keymap, taking precedence over Eat's input-mode maps.
Unbound keys retain their normal Eat or Emacs bindings.")

(defvar-local erleat--emulation-map-alist nil)

(defun erleat--cleanup ()
  "Remove core prompt/input overlays and detach submission markers."
  (erleat--clear-highlights)
  (erleat--forget-input))

(define-minor-mode erleat-mode
  "Customize an Eat buffer for the Erlang shell.
Provide `erleat-mode-map' and highlight prompts and submitted input.
Output and result highlighting remain optional via `erleat-highlight-mode'."
  :lighter nil
  :keymap erleat-mode-map
  (if erleat-mode
      (progn
        (unless (derived-mode-p 'eat-mode)
          (setq erleat-mode nil)
          (user-error "Erleat mode needs an Eat buffer"))
        ;; Use a buffer-local emulation map so customizations also take
        ;; precedence over Eat's character and semi-character minor modes.
        (setq erleat--emulation-map-alist
              `((erleat-mode . ,erleat-mode-map)))
        (setq-local emulation-mode-map-alists
                    (cons 'erleat--emulation-map-alist
                          (remq 'erleat--emulation-map-alist
                                emulation-mode-map-alists)))
        (add-hook 'eat-update-hook #'erleat--highlight nil t)
        (add-hook 'eat-exit-hook #'erleat--highlight nil t)
        (add-hook 'eat-exit-hook #'erleat--forget-input nil t)
        (add-hook 'change-major-mode-hook #'erleat--cleanup nil t)
        (add-hook 'kill-buffer-hook #'erleat--cleanup nil t)
        (erleat--highlight))
    (setq-local emulation-mode-map-alists
                (remq 'erleat--emulation-map-alist emulation-mode-map-alists))
    (remove-hook 'eat-update-hook #'erleat--highlight t)
    (remove-hook 'eat-exit-hook #'erleat--highlight t)
    (remove-hook 'eat-exit-hook #'erleat--forget-input t)
    (remove-hook 'change-major-mode-hook #'erleat--cleanup t)
    (remove-hook 'kill-buffer-hook #'erleat--cleanup t)
    (erleat--cleanup)))


(defconst erleat-version "0.1.0"
  "Version of the Erleat package.")

;;;###autoload
(defun erleat-version ()
  "Return the Erleat package version, displaying it when called interactively."
  (interactive)
  (when (called-interactively-p 'interactive)
    (message "Erleat %s" erleat-version))
  erleat-version)

(defvar-local erleat-buffer-p nil
  "Non-nil in an Eat buffer initialized by `erleat'.
This identifies the buffer even after its Erlang process exits;
it does not indicate whether the process is still running.")

;;;###autoload
(defun erleat ()
  "Start or display an Erlang shell in the *erlang-eat* Eat buffer.
Use `inferior-erlang-machine' and `inferior-erlang-machine-options'
to select the executable and its arguments.  An existing live shell
is reused; a shell that has exited is restarted in the same buffer.
Enable `erleat-mode' when initializing or restarting a shell;
its usual `erleat-mode-hook' performs buffer customization.

The shell starts in `default-directory'.  Display it in another window
when `erlang-inferior-shell-split-window' is non-nil.

Input, history recall, and completion are handled by Erlang through
Eat's terminal keybindings.  Existing Comint-based Erlang commands
are unaffected.  Return the terminal buffer."
  (interactive)
  (unless (require 'eat nil t)
    (user-error "The Eat package is unavailable; install it or add it to load-path"))
  (let ((buffer (apply #'eat-make "erlang-eat"
                       inferior-erlang-machine nil
                       inferior-erlang-machine-options)))
    (with-current-buffer buffer
      (setq-local erleat-buffer-p t)
      (unless erleat-mode
        (erleat-mode 1)))
    (if erlang-inferior-shell-split-window
        (switch-to-buffer-other-window buffer)
      (switch-to-buffer buffer))
    buffer))

(provide 'erleat)

;;; erleat.el ends here
