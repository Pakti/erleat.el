# Erleat = Erlang Shell + Eat for Emacs

Erleat is an inferior Erlang shell for Emacs, using the [Eat](https://codeberg.org/akib/emacs-eat) terminal emulator
instead of Comint -- as is the case with the inferior shell that ships with [Erlang/OTP](https://github.com/erlang/otp) -- in order to avoid display problems experienced with Comint.

## Motivation

Unless started with the `-oldshell` option, the Erlang shell edits and redraws its prompts using terminal control sequences.
With Comint, those redraws can leave duplicated or incorrectly displayed prompts.
Unfortunately, using the `-oldshell` option with `rebar3 shell` as the shell will make `rebar3` crash.  Hence this package based on Eat.
Eat emulates a terminal, allowing Erlang to handle line editing, history, and
completion while Eat renders the screen.

Erleat Mode is a minor mode instead of deriving from Eat Mode because Eat Mode runs some checks on the major mode in its buffers.

## Additions

Erleat reuses options from Erlang shell mode, and aims to mimic its behavior.

Erleat also provides [optional highlighting of printed output and returned
values](#output-and-result-highlighting).

## Setup

You need Emacs 27.1 or later, Eat 0.9.4 or later, Erlang's Emacs mode, and an
installed Erlang/OTP runtime with `erl` on your `PATH`. Install Erlang's Emacs mode separately and ensure `erlang.el` and
`erlang-start.el` are available on Emacs' `load-path`.

1. Install Eat.

2. Download or clone this repository.

3. Add this to your Emacs initialization, adjusting the path:

   ```elisp
   ;; If Erlang mode was installed manually, add its directory as well:
   ;; (add-to-list 'load-path "/path/to/erlang-mode")
   (add-to-list 'load-path "/path/to/erleat")
   (require 'erlang-start)
   (require 'erleat)
   ```

4. Run **`M-x erleat`** to start the Erleat inferior shell.  `erleat` starts or selects `*erlang-eat*`; an exited shell is
   restarted when you invoke the command again.

To select a different executable or arguments, customize these options from Erlang mode:

- `inferior-erlang-machine` and `inferior-erlang-machine-options`;
- `erlang-inferior-shell-split-window` controls whether the terminal opens in another window.

## Everyday use and customization

- Use Erlang's terminal editing, history recall, and Tab completion.
- Navigate prompts with `M-x erleat-previous-shell-prompt` and
  `M-x erleat-next-shell-prompt`, or add custom key bindings to `erleat-mode-map`:
  
  ```elisp
(with-eval-after-load 'erleat
  (define-key erleat-mode-map (kbd "C-v") #'eat-yank)
  (define-key erleat-mode-map (kbd "C-c C-p") #'erleat-previous-shell-prompt)
  (define-key erleat-mode-map (kbd "C-c C-n") #'erleat-next-shell-prompt))
```
  
  `erleat-previous-shell-prompt` and `erleat-next-shell-prompt` use `erleat-prompt-regexp` and accept a
  numeric prefix to move across multiple prompts.
- Ordinary buffer-insertion commands such as
  `clipboard-yank` can fail because the terminal text is read-only.
  Paste with **`C-y`** or **`M-x eat-yank`**. If needed, use `C-c C-j` to select
  Eat's semi-char input mode.
- Use `erleat-mode-hook` to customize the Erleat buffer. `erleat` enables
  `erleat-mode` on initialization and restart, but does not re-enable an already
  active mode when selecting an existing shell. Like other minor-mode hooks,
  this hook also runs when explicitly enabling or disabling the mode.
  The major mode remains `eat-mode`; `erleat-buffer-p` identifies Erleat buffers.
- `erleat-mode-map` bindings take precedence over Eat's input-mode maps; unbound keys retain
  their usual behavior. RET submits input through Eat and records its boundary
  regardless of whether optional output/result highlighting is enabled.
- Run `M-x erleat-version` to display the package version.


### Output and result highlighting

The boolean option `erleat-extra-highlight` controls the highlighting of both
expressions' output and result by enabling the `erleat-highlight-mode` minor mode along with `erleat-mode`.

If you've customized Erlang font-locking with `font-lock-add-keywords` and would like the customization to apply
to results in Erleat buffers, then you must extract the customization into a function to be set as the value of
`erleat-font-lock-add-keywords-function`:

```elisp
(setq erleat-font-lock-add-keywords-function #'my-erlang-font-lock-setup)
```


## Faces

Customize the `erleat-prompt`,
`erleat-input`, `erleat-output`, and `erleat-result` faces independently.

## Scope and development

Highlighting is heuristic: the default prompt pattern recognizes local numbered
prompts, and a result is assumed to be the final unindented line plus its indented
continuations. Custom prompts, prompt-shaped application output, and unusual
pretty printing may need adjustments. Customize `erleat-prompt-regexp` as needed.

The integration has been tested on Linux with Emacs 30.1, Eat 0.9.4, and OTP 27.

For development only, after editing the package, use `M-x load-file` on
[`erleat-load-all.el`](erleat-load-all.el) to reload all Erleat files.

### Tests

Run the ERT suite from the checkout root:

```sh
emacs -Q --batch -l test/run-tests.el
```

The runner initializes locally installed `package.el` packages. Erlang mode,
Eat, and Eat's dependencies must be available on `load-path`. For manually
installed dependencies, supply their directories with `-L` before loading the runner:

```sh
emacs -Q --batch \
  -L /path/to/erlang-mode -L /path/to/eat -L /path/to/compat \
  -l test/run-tests.el
```

The integration tests require a local Erlang runtime and a POSIX environment with
PTY support, `sh`, and `stty`. Put `erl` on `PATH`, or set `ERLEAT_TEST_ERL` to its
executable path. No OTP source build or network access is needed.

Tests cover prompt navigation, redraws, input and result highlighting, custom
font-lock rules, mode lifecycle, keymap precedence, source reloading, and the
stale-RET-keymap regression. They use temporary directories and clean up their
processes and buffers. Close any existing `*erlang-eat*` buffer before running
integration tests interactively; the fixtures refuse to reuse it.

## License

Erleat is licensed under the [GNU General Public License, version 3 or any later version](LICENSE)
(GPL-3.0-or-later).
