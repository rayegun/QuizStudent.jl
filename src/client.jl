# The student client: a persistent websocket connection to the bounce server, a
# background reader task that tracks room state, and the answer-submission logic.

mutable struct StudentClient
    url::String
    name::String
    ws::Any
    sendlock::ReentrantLock
    connected::Bool
    room_key::String
    participant_id::String
    resume_token::String
    sandbox::Module
    current::Union{Nothing,QuestionView}
    open::Bool                  # is the current question accepting answers?
    deadline_ms::Int            # local estimate of the answer deadline
    answered::Set{String}
    n_submitted::Int
    reader::Union{Task,Nothing}
    verbose::Bool
end

function StudentClient(url, name; sandbox::Module=Main)
    StudentClient(url, name, nothing, ReentrantLock(), false, "", "", "",
                  sandbox, nothing, false, 0, Set{String}(), 0, nothing, true)
end

function send!(c::StudentClient, m::Message)
    lock(c.sendlock) do
        c.ws === nothing || WS.send(c.ws, encode(m))
    end
    return nothing
end

remaining_secs(c::StudentClient) = c.deadline_ms == 0 ? 0 : max(0, round(Int, (c.deadline_ms - time() * 1000) / 1000))

# --- inbound message handling --------------------------------------------

function handle(c::StudentClient, m::Joined)
    c.participant_id = m.participant_id
    c.resume_token = m.resume_token
    c.room_key = m.state.room_key
    if m.state.current !== nothing
        c.current = m.state.current
        c.open = true
        c.deadline_ms = round(Int, time() * 1000) + m.state.current.remaining_ms
    end
    m.state.already_answered && c.current !== nothing && push!(c.answered, c.current.id)
    c.verbose && _emit(() -> _banner_joined(c))
    return nothing
end

function handle(c::StudentClient, m::QuestionMsg)
    q = m.question
    c.current = q
    c.open = true
    c.deadline_ms = round(Int, time() * 1000) + q.remaining_ms
    c.verbose && _present_question(c)     # prints + (for code) drops you into quiz>
    return nothing
end

function handle(c::StudentClient, m::AnsweredCount)
    c.current !== nothing && m.question_id == c.current.id && (c.n_submitted = m.n_submitted)
    return nothing
end

function handle(c::StudentClient, m::QuestionClosed)
    if c.current !== nothing && m.question_id == c.current.id
        c.open = false
        c.verbose && _emit(() -> printstyled("\n⏰ Question $(m.question_id) closed ($(m.reason)).\n"; color=:yellow))
    end
    return nothing
end

function handle(c::StudentClient, m::RevealMsg)
    c.verbose && _emit() do
        printstyled("\n── Answer to $(m.question_id) ──\n"; color=:cyan, bold=true)
        isempty(m.expected) || println("expected: ", m.expected)
        isempty(m.explanation) || println(m.explanation)
        println("$(m.n_passed)/$(m.n_submitted) correct")
    end
    return nothing
end

function handle(c::StudentClient, m::Kicked)
    _emit(() -> printstyled("\nYou were removed from the room: $(m.reason)\n"; color=:red, bold=true))
    c.open = false
    return nothing
end

handle(c::StudentClient, m::ErrorMsg) =
    (_emit(() -> printstyled("\n[server error] $(m.code): $(m.message)\n"; color=:red)); nothing)

handle(::StudentClient, ::Pong) = nothing
handle(::StudentClient, ::Message) = nothing   # ignore anything else (e.g. ParticipantList)

# --- connection lifecycle -------------------------------------------------

"""
    connect(url, room_key; name, resume_token=nothing, verbose=true, sandbox=Main) -> StudentClient

Open a persistent connection, join `room_key`, and start the background reader.
Blocks until the join is acknowledged (or errors).

Answers evaluate in `sandbox`, which defaults to `Main` so they share the student's
live REPL namespace (packages and variables from the `julia>` prompt are in scope, and
bindings answers create show up there too). Pass `QuizStudent.new_sandbox()` for an
isolated clean room instead.
"""
function connect(url::AbstractString, room_key::AbstractString;
                 name::AbstractString, resume_token=nothing, verbose::Bool=true,
                 sandbox::Module=Main)
    c = StudentClient(url, name; sandbox=sandbox)
    c.verbose = verbose
    ready = Channel{Bool}(1)
    c.reader = @async begin
        try
            WS.open(url) do ws
                c.ws = ws
                c.connected = true
                send!(c, Join(room_key=room_key, name=name, resume_token=resume_token))
                for raw in ws
                    local m
                    try
                        m = decode(String(raw))
                    catch
                        continue
                    end
                    try
                        handle(c, m)        # a handler error must never kill the reader
                    catch e
                        verbose && @debug "message handler error" exception=e
                    end
                    m isa Joined && isready(ready) == false && put!(ready, true)
                end
            end
        catch e
            verbose && @warn "connection closed" exception=e
        finally
            c.connected = false
            isready(ready) || (try; put!(ready, false); catch; end)
        end
    end
    # wait for join ack (or failure) up to 5s
    t0 = time()
    while !isready(ready) && (time() - t0) < 5.0
        sleep(0.02)
    end
    return c
end

disconnect!(c::StudentClient) = (c.ws === nothing || (try; close(c.ws); catch; end); nothing)

# --- answering ------------------------------------------------------------

"""
    submit(client, code::AbstractString) -> value

Evaluate `code` locally, grade it with the current question's checker, report the
result to the server, and return the computed value (so the REPL can display it).
"""
function submit(c::StudentClient, code::AbstractString)
    q = c.current
    if q === nothing
        printstyled("No active question yet.\n"; color=:yellow); return nothing
    end
    if q.kind === :choice
        printstyled("$(q.id) is multiple choice — run choose() to pick an option.\n"; color=:yellow)
        return nothing
    end
    if q.kind === :open
        printstyled("$(q.id) is short answer — run respond(\"…\") to send your text.\n"; color=:yellow)
        return nothing
    end
    if !c.open
        printstyled("Question $(q.id) is closed — too late.\n"; color=:yellow); return nothing
    end
    if q.id in c.answered
        printstyled("You already answered $(q.id).\n"; color=:yellow); return nothing
    end

    r = evaluate(c.sandbox, code, q.checker_src)

    if r.error !== nothing
        printstyled("✗ error: "; color=:red, bold=true); println(r.error)
    elseif r.passed
        printstyled("✓ correct"; color=:green, bold=true); println("  ($(r.elapsed_ms) ms)")
    else
        printstyled("✗ not quite"; color=:red, bold=true); println("  → $(r.repr)")
    end

    push!(c.answered, q.id)
    send!(c, Answer(question_id=q.id, code=code, passed=r.passed, result_repr=r.repr,
                    stdout=r.stdout, elapsed_ms=r.elapsed_ms, error=r.error))
    return r.value
end

"""
    choose(client, idx::Integer) -> idx

Submit option `idx` (1-based) for the current multiple-choice question. Grading happens
on the server (the correct answer is never sent to you), so you'll learn if you were
right when the host reveals.
"""
function choose!(c::StudentClient, idx::Integer)
    q = c.current
    q === nothing && (printstyled("No active question.\n"; color=:yellow); return nothing)
    q.kind === :choice ||
        (printstyled("$(q.id) isn't multiple choice — answer in quiz> instead.\n"; color=:yellow); return nothing)
    !c.open && (printstyled("Question $(q.id) is closed — too late.\n"; color=:yellow); return nothing)
    q.id in c.answered && (printstyled("You already answered $(q.id).\n"; color=:yellow); return nothing)
    (1 <= idx <= length(q.choices)) ||
        (printstyled("Pick a number from 1 to $(length(q.choices)).\n"; color=:yellow); return nothing)

    label = q.choices[idx]
    push!(c.answered, q.id)
    send!(c, Answer(question_id=q.id, code="", passed=false, choice=Int(idx), result_repr=label))
    printstyled("✓ submitted: "; color=:green, bold=true); println("$(idx). $(label)")
    return idx
end

"Interactive picker (TerminalMenus radio buttons) for the current choice question."
function choose!(c::StudentClient)
    q = c.current
    (q === nothing || q.kind !== :choice) &&
        (printstyled("No multiple-choice question active.\n"; color=:yellow); return nothing)
    !c.open && (printstyled("Question $(q.id) is closed — too late.\n"; color=:yellow); return nothing)
    q.id in c.answered && (printstyled("You already answered $(q.id).\n"; color=:yellow); return nothing)
    idx = TerminalMenus.request("$(q.prompt)", TerminalMenus.RadioMenu(q.choices))
    idx == -1 && (println("(cancelled)"); return nothing)
    return choose!(c, idx)
end

"""
    respond(text)   # send free text for a short-answer question
    respond()       # prompt for a line, then send it

Answer the current short-answer (`:open`) question. There's no checker — responses are
just collected for the host to browse.
"""
function respond!(c::StudentClient, text::AbstractString)
    q = c.current
    q === nothing && (printstyled("No active question.\n"; color=:yellow); return nothing)
    q.kind === :open ||
        (printstyled("$(q.id) isn't a short-answer question.\n"; color=:yellow); return nothing)
    !c.open && (printstyled("Question $(q.id) is closed — too late.\n"; color=:yellow); return nothing)
    q.id in c.answered && (printstyled("You already answered $(q.id).\n"; color=:yellow); return nothing)
    s = strip(text)
    isempty(s) && (printstyled("Empty response — nothing sent.\n"; color=:yellow); return nothing)

    push!(c.answered, q.id)
    send!(c, Answer(question_id=q.id, code="", passed=false, result_repr=String(s)))
    printstyled("✓ submitted: "; color=:green, bold=true); println(s)
    return String(s)
end

function respond!(c::StudentClient)
    q = c.current
    (q === nothing || q.kind !== :open) &&
        (printstyled("No short-answer question active.\n"; color=:yellow); return nothing)
    print("your answer> "); flush(stdout)
    return respond!(c, readline())
end

# --- display helpers ------------------------------------------------------

function _banner_joined(c::StudentClient)
    printstyled("\nJoined room $(c.room_key) as \"$(c.name)\".\n"; color=:green, bold=true)
    printstyled("Resume token: $(c.resume_token)  "; color=:light_black)
    printstyled("(keep this to rejoin if you disconnect)\n"; color=:light_black)
    c.current !== nothing && show_question(c)
    return nothing
end

"Pretty-print the current question."
function show_question(c::StudentClient)
    q = c.current
    q === nothing && (println("No active question."); return nothing)
    println()
    printstyled("┃ Question $(q.id)"; color=:magenta, bold=true)
    c.open ? printstyled("  ($(remaining_secs(c))s left)\n"; color=:light_black) : printstyled("  (closed)\n"; color=:yellow)
    println(q.prompt)
    if q.kind === :choice && !isempty(q.choices)
        for (i, opt) in enumerate(q.choices)
            printstyled("  $i. "; color=:light_black); println(opt)
        end
        printstyled("At quiz>: press Enter for the menu, or type the option number.  (choose(n) from julia>.)\n"; color=:cyan)
    elseif q.kind === :open
        printstyled("At quiz>: type your answer and press Enter.  (respond(\"…\") from julia>.)\n"; color=:cyan)
    else
        isempty(q.starter_code) || (printstyled("starter: "; color=:light_black); println(q.starter_code))
    end
    return nothing
end
