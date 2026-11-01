# Erleat = Erlang + Eat

An Erlang shell for Emacs, using [Eat](https://codeberg.org/akib/emacs-eat)
instead of Emacs' Comint in order to avoid display problems with the latter.

Unless started with the `-oldshell` option, the Erlang shell edits and redraws its prompts using terminal control sequences.
With Comint, those redraws can leave duplicated or incorrectly displayed prompts.
Unfortunately, using the `-oldshell` option with `rebar3 shell` as the shell will make `rebar3` crash.  Hence this package based on Eat.
Eat emulates a terminal, allowing Erlang to handle line editing, history, and
completion while Eat renders the screen.

Erleat is a small adapter around the existing Erlang mode. It reuses its executable,
argument, and window settings without modifying Erlang mode.
Prompts and submitted input are highlighted automatically; printed output and
returned values can be highlighted separately with an optional minor mode.

## Setup

You need Emacs 27.1 or later, Eat 0.9.4 or later, Erlang's Emacs mode, and an
installed Erlang/OTP runtime with `erl` on your `PATH`. A prebuilt runtime is
sufficient. Install Erlang's Emacs mode separately and ensure `erlang.el` and
`erlang-start.el` are available on Emacs' `load-path`.

1. Install Eat using your preferred package manager. For example:

   ```elisp
   (require 'package)
   (add-to-list 'package-archives
                '("nongnu" . "https://elpa.nongnu.org/nongnu/"))
   ```

   Then run `M-x package-refresh-contents` and `M-x package-install RET eat RET`.

2. Download or clone the Erleat repository.

3. Add this to your Emacs initialization, adjusting the path:

   ```elisp
   ;; If Erlang mode was installed manually, add its directory as well:
   ;; (add-to-list 'load-path "/path/to/erlang-mode")
   (add-to-list 'load-path "/path/to/erleat")
   (require 'erlang-start)
   (require 'erleat)
   ```

4. Run **`M-x erleat`**. It starts or selects `*erlang-eat*`; an exited shell is
   restarted when you invoke the command again.

To select a different executable or arguments, customize `inferior-erlang-machine`
and `inferior-erlang-machine-options`. `erlang-inferior-shell-split-window` controls
whether the terminal opens in another window.

## Everyday use and customization

- Use Erlang's terminal editing, history recall, and Tab completion.
- Navigate prompts with `M-x erleat-previous-shell-prompt` and
  `M-x erleat-next-shell-prompt`. Both use `erleat-prompt-regexp` and accept a
  numeric prefix to move across multiple prompts. Point lands at the end of the
  prompt, immediately before the user input.
- Paste with **`C-y`** or **`M-x eat-yank`**. If needed, use `C-c C-j` to select
  Eat's semi-char input mode. Ordinary buffer-insertion commands such as
  `clipboard-yank` can fail because the terminal text is read-only.
- Use `erleat-mode-hook` to customize the terminal buffer. `erleat` enables
  `erleat-mode` on initialization and restart, but does not re-enable an already
  active mode when selecting an existing shell. Like other minor-mode hooks,
  this hook also runs when explicitly enabling or disabling the mode.
  The major mode remains `eat-mode`; `erleat-buffer-p` identifies Erleat buffers.
- Customize `erleat-mode-map` for mode-specific bindings.
  Its bindings take precedence over Eat's input-mode maps; unbound keys retain
  their usual behavior. RET submits input through Eat and records its boundary
  regardless of whether optional output/result highlighting is enabled.
- Run `M-x erleat-version` to display the package version.

To enable optional output/result highlighting for new shells:

```elisp
(add-hook 'erleat-mode-hook
          (lambda ()
            (erleat-highlight-mode (if erleat-mode 1 -1))))
```

For an existing shell, run `M-x erleat-highlight-mode`. It observes the submissions
recorded by `erleat-mode`, distinguishes printed output from the returned value,
and fontifies that value with Erlang mode. It does not bind keys or send input.
For example:

```erlang
io:format("This is printed output.~n"), {ok, 42, "returned value"}.
```

If your source buffers use a custom `font-lock-add-keywords` setup function,
assign that same no-argument function to `erleat-font-lock-add-keywords-function`:

```elisp
(setq erleat-font-lock-add-keywords-function #'my-erlang-font-lock-setup)
```

The function runs in the temporary result buffer after activating Erlang mode,
before fontification. Its default is `nil`; ordinary source-buffer hooks are not run.
Overlay-based highlighters are not copied. Customize the `erleat-prompt`,
`erleat-input`, `erleat-output`, and `erleat-result` faces independently.

## Scope and development

The existing Erlang compile and EUnit commands still use their original Comint
backend. Erleat currently provides an alternative terminal, not a replacement for
those commands.

Highlighting is heuristic: the default prompt pattern recognizes local numbered
prompts, and a result is assumed to be the final unindented line plus its indented
continuations. Custom prompts, prompt-shaped application output, and unusual
pretty printing may need adjustments. Customize `erleat-prompt-regexp` as needed.

The integration has been tested on Linux with Emacs 30.1, Eat 0.9.4, and OTP 27.

After editing the package, use `M-x load-file` on
[`erleat-load-all.el`](erleat-load-all.el). It reloads
[`erleat-highlight.el`](erleat-highlight.el) and [`erleat.el`](erleat.el) from source,
bypassing stale `.elc` files, without reloading Erlang mode or Eat.
