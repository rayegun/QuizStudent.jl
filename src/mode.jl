# Interactive layer: a ReplMaker mode where each entry is evaluated locally, graded,
# submitted, and its value displayed — keeping the natural REPL feel. This file only
# does anything useful inside a live REPL session.

# The client the REPL mode talks to, plus the installed `quiz>` mode object and whether
# to auto-enter it when a question arrives.
const ACTIVE = Ref{Union{Nothing,StudentClient}}(nothing)
const QUIZMODE = Ref{Any}(nothing)
const AUTO_ENTER = Ref(true)

# The active REPL's line-editor state, or nothing outside an interactive REPL.
function _mistate()
    try
        repl = Base.active_repl
        return (repl isa REPL.LineEditREPL) ? repl.mistate : nothing
    catch
        return nothing
    end
end

# Emit background output the right way: wipe the displayed prompt+input, print `f()`'s
# text ABOVE it, then redraw the prompt below (so a message never lands after `quiz> `
# leaving a stray blank line). `after(mi, st)` runs in place of the default redraw — we
# use it to switch into `quiz>` for an arriving question.
#
# Safe from the reader task: `clear_input_area`/`refresh_line`/`transition` take no lock
# (only the editor's own consumer loops take `line_modify_lock`) and never block, so this
# can glitch under a multi-thread race at worst — it can never hang. Falls back to a plain
# print with no interactive REPL.
function _above_prompt(f::Function; after=nothing)
    mi = _mistate()
    if mi === nothing
        f(); return nothing
    end
    try
        st = REPL.LineEdit.state(mi)
        REPL.LineEdit.clear_input_area(REPL.LineEdit.terminal(st), st)
        f()
        after === nothing ? REPL.LineEdit.refresh_line(st) : after(mi, st)
    catch
        f()
    end
    return nothing
end

# Output coming from the background reader task.
_emit(f::Function) = _above_prompt(f)

# A question arrived: print it above the prompt, then drop into `quiz>` ready to answer
# (the parser routes by question kind — code/open/choice — once they hit Enter).
function _present_question(c::StudentClient)
    _above_prompt(() -> show_question(c); after = function (mi, st)
        if AUTO_ENTER[] && QUIZMODE[] !== nothing && REPL.LineEdit.mode(mi) !== QUIZMODE[]
            ReplMaker.enter_mode!(QUIZMODE[])      # switch to quiz> (redraws)
        else
            REPL.LineEdit.refresh_line(st)         # already in quiz> / auto off: redraw
        end
    end)
end

# Called by ReplMaker for each completed `quiz>` entry. Dispatches by question kind, so
# the SAME prompt handles code, short answer, and multiple choice. Crucially, the choice
# menu runs HERE (evaluation context, no editor lock held) — the safe place for it.
function _parser(input::AbstractString)
    c = ACTIVE[]
    if c === nothing
        printstyled("Not connected. Run `join_quiz(...)` first.\n"; color=:yellow)
        return nothing
    end
    q = c.current
    if q !== nothing && q.kind === :choice
        n = tryparse(Int, strip(input))
        return n === nothing ? choose!(c) : choose!(c, n)   # Enter ⇒ menu; a number ⇒ that option
    elseif q !== nothing && q.kind === :open
        return respond!(c, input)
    else
        return submit(c, input)                              # code (or no question)
    end
end

"""
    startmode(; start_key=")", mode_name="quiz", auto_enter=true)

Register the quiz answer mode on the active REPL. Press `start_key` at an empty
`julia>` prompt to enter it; backspace at the start returns to the Julia prompt.

With `auto_enter=true` (default) you're dropped into `quiz>` automatically when a question
arrives. There the prompt adapts to the question: type code, type short-answer text, or —
for multiple choice — press Enter for the radio menu (or just type the option number).
"""
function startmode(; start_key=")", mode_name="quiz", auto_enter=true)
    mode = ReplMaker.initrepl(_parser;
        prompt_text = "quiz> ",
        prompt_color = :magenta,
        start_key = start_key,
        mode_name = mode_name,
        valid_input_checker = ReplMaker.complete_julia,
    )
    QUIZMODE[] = mode
    AUTO_ENTER[] = auto_enter
    return mode
end

"""
    join_quiz(; url, room_key, name, resume_token=nothing, start_key=")", sandbox=Main) -> StudentClient

Connect to a room and install the answer REPL mode. The returned client also becomes
the [`ACTIVE`](@ref) one used by the mode and the `question()`/`status()` helpers.

Answers evaluate in `sandbox` (default `Main`), so the `quiz>` mode shares state with
the normal `julia>` prompt: experiment and load packages at `julia>`, then press
`start_key` to answer using everything you've set up. Backspace at an empty `quiz>`
prompt returns to `julia>`. Pass `QuizStudent.new_sandbox()` for an isolated room.

Reconnecting is automatic: the resume token issued on your first join is saved to
LocalPreferences.toml, so re-running `join_quiz` for the same room picks up your
identity and already-answered state. Pass `resume_token` to override, or
[`forget_resume_token!`](@ref) to rejoin fresh.
"""
function join_quiz(; url=nothing, room_key::AbstractString, name::AbstractString,
                   resume_token=nothing, start_key=")", sandbox::Module=Main,
                   auto_enter=true)
    u = url === nothing ? server_url() : String(url)
    isempty(u) && error("no server URL — pass url=\"wss://…\" once (it will be remembered).")
    tok = resume_token === nothing ? remembered_resume_token(u, room_key) : resume_token
    c = connect(u, room_key; name=name, resume_token=tok, sandbox=sandbox)
    ACTIVE[] = c
    if c.connected
        url === nothing || set_url!(u)                          # save the URL on first use
        isempty(c.resume_token) || remember_resume_token!(u, room_key, c.resume_token)
    end
    try
        startmode(; start_key=start_key, auto_enter=auto_enter)
        printstyled("Press `$(start_key)` at the julia> prompt to answer "; color=:cyan)
        printstyled("(backspace returns to julia>).\n"; color=:cyan)
    catch e
        @warn "couldn't install the REPL mode (are you in an interactive REPL?)" exception=e
    end
    return c
end

# --- helpers usable from the normal julia> prompt -------------------------

_active() = (ACTIVE[] === nothing && error("no active quiz; run join_quiz(...)"); ACTIVE[])

"Reprint the current question."
question() = show_question(_active())

"""
    choose()        # interactive radio-button menu
    choose(n)       # pick option n directly

Answer the current multiple-choice question. The correct option is graded on the server
and never sent to you, so you'll find out when the host reveals.
"""
choose() = choose!(_active())
choose(n::Integer) = choose!(_active(), n)

"""
    respond(text)   # send free text for a short-answer question
    respond()       # prompt for a line, then send it
"""
respond() = respond!(_active())
respond(text::AbstractString) = respond!(_active(), text)

"Show connection / question status."
function status()
    c = _active()
    println("room:   ", c.room_key)
    println("name:   ", c.name)
    println("state:  ", c.connected ? "connected" : "disconnected")
    if c.current !== nothing
        println("q:      ", c.current.id, c.open ? "  ($(remaining_secs(c))s left)" : "  (closed)")
        println("you:    ", (c.current.id in c.answered) ? "answered" : "not answered")
        println("count:  ", c.n_submitted, " submitted")
    end
    return nothing
end

"Leave the room and close the connection."
function leave()
    c = _active()
    send!(c, Leave())
    disconnect!(c)
    ACTIVE[] = nothing
    println("Left the room.")
    return nothing
end
