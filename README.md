# Erlang shell extensions for Emacs

A targeted redraw filter and optional output/result highlighting for the original
Comint-based `erlang-shell-mode`. Both libraries leave Erlang mode's commands,
key bindings, compilation, EUnit integration, and history handling in place.

## Why a filter?

The modern Erlang shell redraws submitted expressions using terminal control
sequences. In Comint, this can leave a second copy of the prompt and expression,
particularly when running `rebar3 shell`.

[`erlang-comint-redraw.el`](erlang-comint-redraw.el) suppresses a redraw only when
its text exactly matches the expression just submitted. Comint keeps the original
prompt and input, including their highlighting. Multiline expressions and
sequences split across process output chunks are supported.

The filter is **Erlang-shell-specific**, not a general terminal emulator. It
recognizes Erlang's numbered prompts, continuation prompts, and submitted-input
redraws with the default shell formatter. Unknown output passes through unchanged;
incomplete candidates are bounded in size and have an idle timeout. Custom shell
formatters and arbitrary terminal editing are outside its scope.

## Setup

You need Emacs 27.1 or later, Erlang's Emacs mode on `load-path`, and an installed
Erlang/OTP runtime. Use your existing configuration for `erl` or `rebar3 shell`.
No OTP source build or additional terminal package is needed.

Put the libraries on `load-path`, then add:

```elisp
(add-to-list 'load-path "/path/to/these-libraries")
(require 'erlang-start)
(require 'erlang-comint-redraw)
(add-hook 'erlang-shell-mode-hook #'erlang-comint-redraw-mode)
```

Start the original shell with `M-x erlang-shell`. For a buffer already running,
enable `M-x erlang-comint-redraw-mode` before submitting another expression.
Keep `comint-process-echoes` enabled, as Erlang mode normally does. For custom
numbered prompts, customize `erlang-comint-redraw-prompt-regexp`.

## Optional output and result highlighting

[`erlang-shell-highlight.el`](erlang-shell-highlight.el) distinguishes printed
output from returned values. It works with the redraw filter or the old Erlang
shell, and is enabled independently:

```elisp
(require 'erlang-shell-highlight)
(add-hook 'erlang-shell-mode-hook #'erlang-shell-highlight-mode)
```

You can also toggle `M-x erlang-shell-highlight-mode` in an existing shell.
Disabling it removes its overlays; prompt and input highlighting remain managed
by Erlang mode and Comint. RET keeps its original behavior, including compiler
error navigation. Commands that submit through `comint-send-input`, including
upstream compilation commands, are tracked without replacing their implementation.

For example:

```erlang
io:format("Printed output.~n"), {ok, 42, "returned value"}.
```

Printed text uses `erlang-shell-highlight-output`. The returned term uses Erlang
syntax highlighting, falling back to `erlang-shell-highlight-result` where no
syntax face applies. Both fallback faces inherit `default` and can be customized.

The distinction is heuristic: the final unindented line and its indented
continuations are treated as the returned value. Prompt-shaped application output,
unusual pretty printing, and asynchronous output during evaluation can confuse
this heuristic.

### Custom syntax highlighting

Results are fontified in a temporary `erlang-mode` buffer. For efficiency,
`erlang-mode-hook` and `prog-mode-hook` are suppressed so that source-buffer
services such as Flymake are not started for every result. Font lock itself is
used normally.

If you add custom keywords in your source-buffer hooks, put that setup in a
function and reuse it here:

```elisp
(defun my-erlang-font-lock-setup ()
  (font-lock-add-keywords
   nil '(("," . font-lock-keyword-face))))

(add-hook 'erlang-mode-hook #'my-erlang-font-lock-setup)
(setq erlang-shell-highlight-font-lock-add-keywords-function
      #'my-erlang-font-lock-setup)
```

The function runs before fontification. Text-property faces are copied into
shell overlays; overlays created by other highlighting packages are not copied.

## Tests

```sh
emacs -Q --batch -L /path/to/erlang-mode -l test/run-comint-tests.el
```

The runner initializes installed `package.el` packages. The real-shell tests
require a POSIX PTY environment and `rebar3` on `PATH`, or its executable path in
`ERLANG_COMINT_REDRAW_REBAR3`; otherwise those tests are skipped. They use temporary
directories and clean up their processes and buffers.

Tests cover chunk boundaries, unknown output, timeout handling, mode lifecycle,
syntax faces and custom font-lock rules, synchronous output during submission,
and split prompts. Real-shell tests exercise the original command sender and
compilation, `r3` availability, multiline input, and asynchronous output with
unfinished input, with and without optional highlighting.

Verified with Emacs 30.1, Erlang/OTP 27.3.4.1, and rebar3 3.24.0.

## License

These libraries are licensed under the [GNU General Public License, version 3
or any later version](LICENSE) (GPL-3.0-or-later).
