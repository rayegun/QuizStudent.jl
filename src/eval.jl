# Local, in-process evaluation of a student's answer and the question's reference
# checker. This is the heart of "trust-the-client": the student's code runs here, in
# their own process, never on the server or the teacher's machine.
#
# By default the evaluation module is `Main` (see client.jl), so answers share the
# student's live REPL namespace — packages they `using`'d and variables they defined at
# the `julia>` prompt are in scope, and bindings an answer creates are visible back at
# `julia>`. Pass an isolated `Module` instead if you want a clean room.

"Result of evaluating one answer."
struct EvalResult
    value::Any
    repr::String
    stdout::String
    passed::Bool
    error::Union{Nothing,String}
    elapsed_ms::Int
end

const REPR_LIMIT = 400

function _short(s::AbstractString, limit::Integer=REPR_LIMIT)
    s = String(s)
    return length(s) <= limit ? s : string(first(s, limit), " …")
end

"A fresh, isolated module (with Base/Core imported) — opt-in clean room for evaluation."
new_sandbox() = Module(:QuizSandbox)

"""
    evaluate(mod::Module, code::AbstractString, checker_src::AbstractString) -> EvalResult

Evaluate `code` in `mod` (capturing stdout/stderr), then, if `checker_src` is a
non-empty `() -> Bool` source, evaluate it in the same module and call it to decide
`passed`. Bindings created by `code` persist in `mod` across questions, so the checker
can inspect them and later answers can build on earlier ones.

`mod` is `Main` for a live student session, so answers share the REPL namespace; tests
pass a fresh [`new_sandbox`](@ref) for isolation.
"""
function evaluate(sandbox::Module, code::AbstractString, checker_src::AbstractString)
    t0 = time_ns()
    parsed = try
        Meta.parseall(code)
    catch e
        return EvalResult(nothing, "", "", false, "parse error: " * sprint(showerror, e), 0)
    end

    c = IOCapture.capture(rethrow=Union{}) do
        Core.eval(sandbox, parsed)
    end
    elapsed = round(Int, (time_ns() - t0) / 1_000_000)

    if c.error
        return EvalResult(nothing, "", c.output, false, sprint(showerror, c.value), elapsed)
    end

    value = c.value
    valrepr = _short(sprint(show, value))

    passed = false
    if !isempty(checker_src)
        cc = IOCapture.capture(rethrow=Union{}) do
            f = Core.eval(sandbox, Meta.parse(checker_src))
            Base.@invokelatest f()          # avoid world-age issues after eval
        end
        passed = !cc.error && cc.value === true
    end

    return EvalResult(value, valrepr, c.output, passed, nothing, elapsed)
end
