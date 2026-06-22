"""
    QuizStudent

Student client for ReplQuiz. Connects to a room on the bounce server, receives
questions, and provides a ReplMaker answer mode where each entry is evaluated in a
local sandbox, graded against the question's reference checker, reported to the
server, and displayed — all in the student's own process (trust-the-client).

Interactive entry point: [`join_quiz`](@ref). Helpers: `question()`, `status()`,
`leave()`.
"""
module QuizStudent

using HTTP
import HTTP.WebSockets as WS
using QuizProtocol
import ReplMaker
import IOCapture
using Preferences
import REPL
import REPL.TerminalMenus

export join_quiz, question, choose, respond, status, leave, forget_resume_token!
export StudentClient, connect, submit, choose!, respond!, evaluate   # programmatic / testing API

include("auth.jl")
include("eval.jl")
include("client.jl")
include("mode.jl")

end # module
