# QuizStudent

[![Build Status](https://github.com/rayegun/QuizStudent.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/rayegun/QuizStudent.jl/actions/workflows/CI.yml?query=branch%3Amain)

Student client for **ReplQuiz** — a Kahoot-style, REPL-driven quiz system for teaching
Julia. Join a room, get questions, and answer them in a `quiz>` REPL mode that runs each
entry in your own session, grades it against the question's checker, and reports the
result to the server.

The student's process is the only place answers run (trust-the-client): the server and
teacher never execute your code, they only see `{code, value, passed}`.

## Quick start

```julia
using QuizStudent
join_quiz(url = "ws://your-server:8080", room_key = "T4CMAP", name = "Grace")
```

When a question arrives you're dropped into the `quiz>` prompt automatically, and it
adapts to the question:

- **Code:** type your Julia answer and press Enter on a complete expression.
- **Multiple choice:** press Enter for a radio-button menu (`REPL.TerminalMenus`), or just
  type the option number. Graded on the server, so the answer stays hidden until reveal.
- **Short answer:** type your text and press Enter — no grading, just collected for the host.

Backspace at an empty `quiz>` prompt returns you to `julia>`, and `)` re-enters. The same
actions work from the normal prompt too: `choose()` / `choose(n)`, `respond("…")`, and
`submit("code")`. Helpers: `question()` reprints the current question, `status()` shows
your state, `leave()` exits. Disable the auto-enter with `join_quiz(...; auto_enter=false)`.

## Answers share your REPL session

`quiz>` answers evaluate in **`Main`** — the same namespace as the normal `julia>`
prompt. This is deliberate: ReplQuiz is for teaching *interactive* REPL usage, so

- packages you `using` and variables you define at `julia>` are in scope in your answers,
- bindings your answers create show up back at `julia>` for inspection and reuse,
- you can freely toggle between `julia>` (experiment, load packages, build helpers) and
  `quiz>` (submit using everything you've set up).

If you'd rather grade answers in a clean room (each answer isolated from your session),
pass an isolated module:

```julia
join_quiz(url = "...", room_key = "...", name = "...", sandbox = QuizStudent.new_sandbox())
```

## Reconnecting

Reconnecting is automatic. On your first join the server issues a private resume token,
and `join_quiz` saves it (per server+room) in `LocalPreferences.toml`. If you drop, just
re-run the same `join_quiz` within the room's grace window — you pick up your identity
and already-answered state with no token to copy:

```julia
join_quiz(url = "...", room_key = "...", name = "Grace")   # resumes if a token is saved
```

Override with `resume_token = "…"`, or start fresh with
`forget_resume_token!(url, room_key)`.

## Programmatic API

`connect`, `submit`, and `evaluate` are exported for scripted/testing use without a live
REPL. `evaluate(mod, code, checker_src)` is the pure grading core.

Part of the [ReplQuiz](../DESIGN.md) workspace alongside `QuizProtocol`, `QuizServer`,
and `QuizTeacher`.
