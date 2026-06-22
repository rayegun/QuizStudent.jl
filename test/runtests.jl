using QuizStudent
using QuizProtocol
using Test

@testset "QuizStudent.evaluate" begin
    @testset "correct value answer" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "ans = [1,4,9]", "() -> ans == [1,4,9]")
        @test r.error === nothing
        @test r.passed
        @test r.value == [1, 4, 9]
        @test occursin("1", r.repr)
    end

    @testset "incorrect answer" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "ans = [1,2,3]", "() -> ans == [1,4,9]")
        @test r.error === nothing
        @test !r.passed
    end

    @testset "behavioral checker (function definition)" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "sq(x) = x^2", "() -> sq(3) == 9 && sq(-2) == 4")
        @test r.error === nothing
        @test r.passed
    end

    @testset "runtime error is captured, not thrown" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "error(\"boom\")", "() -> true")
        @test r.error !== nothing
        @test occursin("boom", r.error)
        @test !r.passed
    end

    @testset "parse error is captured" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "1 +", "() -> true")
        @test r.error !== nothing
        @test !r.passed
    end

    @testset "stdout is captured" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "println(\"hi there\"); 42", "() -> true")
        @test occursin("hi there", r.stdout)
        @test r.value == 42
        @test r.passed
    end

    @testset "bindings persist across answers in a session" begin
        m = QuizStudent.new_sandbox()
        evaluate(m, "base = 10", "")
        r = evaluate(m, "doubled = base * 2", "() -> doubled == 20")
        @test r.passed
    end

    @testset "empty checker cannot pass" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "1 + 1", "")
        @test r.error === nothing
        @test r.value == 2
        @test !r.passed          # no checker => not graded correct
    end

    @testset "checker that errors -> not passed" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "x = 1", "() -> undefined_thing == 1")
        @test r.error === nothing      # the answer itself ran fine
        @test !r.passed                # checker blew up
    end

    @testset "repr is truncated" begin
        m = QuizStudent.new_sandbox()
        r = evaluate(m, "collect(1:10_000)", "() -> true")
        @test length(r.repr) <= QuizStudent.REPR_LIMIT + 4
    end
end

@testset "session namespace sharing" begin
    @testset "client evaluates in Main by default" begin
        c = StudentClient("ws://x", "Tester")
        @test c.sandbox === Main
    end

    @testset "answers see vars/packages from the live session, and leak back" begin
        # stand in for the student's normal julia> prompt
        Main.eval(:(quiz_helper(x) = x + 1000))
        Main.eval(:(quiz_seed = [2, 3, 4]))

        r = evaluate(Main, "quiz_total = sum(quiz_seed) + quiz_helper(0)",
                     "() -> quiz_total == 1009")
        @test r.error === nothing
        @test r.passed                                  # checker saw the answer's binding
        @test isdefined(Main, :quiz_total)              # binding is visible back at julia>
        @test Main.quiz_total == 1009
    end

    @testset "an isolated sandbox does NOT see the session" begin
        Main.eval(:(quiz_secret = 7))
        r = evaluate(QuizStudent.new_sandbox(), "quiz_secret + 1", "")
        @test r.error !== nothing                       # UndefVarError — clean room
    end
end

@testset "multiple-choice answering" begin
    c = StudentClient("ws://x", "Tester")     # ws === nothing ⇒ send! is a no-op
    @test choose!(c, 1) === nothing            # no active question

    c.current = QuestionView(id="mc", kind=:choice, prompt="pick b", starter_code="",
                             checker_src="", remaining_ms=10_000, choices=["a", "b", "c"])
    c.open = true

    @test choose!(c, 9) === nothing            # out of range
    @test !("mc" in c.answered)
    @test choose!(c, 2) == 2                    # valid pick records the answer
    @test "mc" in c.answered
    @test choose!(c, 1) === nothing            # duplicate ignored

    # submit() refuses a choice question and does not consume the answer
    c2 = StudentClient("ws://x", "T2")
    c2.current = QuestionView(id="mc2", kind=:choice, prompt="p", starter_code="",
                              checker_src="", remaining_ms=10_000, choices=["x", "y"])
    c2.open = true
    @test submit(c2, "1 + 1") === nothing
    @test !("mc2" in c2.answered)

    # choose! refuses a code question
    c3 = StudentClient("ws://x", "T3")
    c3.current = QuestionView(id="code1", kind=:code, prompt="p", starter_code="",
                              checker_src="", remaining_ms=10_000, choices=String[])
    c3.open = true
    @test choose!(c3, 1) === nothing
end

@testset "short-answer (open) responding" begin
    c = StudentClient("ws://x", "Tester")
    c.current = QuestionView(id="op", kind=:open, prompt="name a Julia package", starter_code="",
                             checker_src="", remaining_ms=10_000, choices=String[])
    c.open = true

    @test respond!(c, "   ") === nothing            # empty/whitespace ⇒ nothing sent
    @test !("op" in c.answered)
    @test respond!(c, "  HTTP.jl ") == "HTTP.jl"     # trimmed, recorded
    @test "op" in c.answered
    @test respond!(c, "again") === nothing           # duplicate ignored

    # submit() and choose() refuse an open question
    c2 = StudentClient("ws://x", "T2")
    c2.current = c.current; c2.open = true
    @test submit(c2, "1 + 1") === nothing
    @test choose!(c2, 1) === nothing
    @test !("op" in c2.answered)
end

@testset "quiz> parser routes by question kind" begin
    c = StudentClient("ws://x", "T")        # ws === nothing ⇒ sends are no-ops
    QuizStudent.ACTIVE[] = c
    try
        # code question → evaluate + submit, returns the value
        c.current = QuestionView(id="code", kind=:code, prompt="p", starter_code="",
                                 checker_src="() -> qp_ans == 4", remaining_ms=9000, choices=String[])
        c.open = true
        @test QuizStudent._parser("qp_ans = 4") == 4

        # short answer → respond with the typed text
        c.current = QuestionView(id="op", kind=:open, prompt="p", starter_code="",
                                 checker_src="", remaining_ms=9000, choices=String[])
        c.open = true
        @test QuizStudent._parser("a free response") == "a free response"

        # multiple choice → a typed number picks that option (no terminal needed)
        c.current = QuestionView(id="mc", kind=:choice, prompt="p", starter_code="",
                                 checker_src="", remaining_ms=9000, choices=["a", "b", "c"])
        c.open = true
        @test QuizStudent._parser("2") == 2
        @test "mc" in c.answered
    finally
        QuizStudent.ACTIVE[] = nothing
    end
end

@testset "resume-token persistence" begin
    url, key = "ws://test:9999", "ABC234"
    QuizStudent.forget_resume_token!(url, key)          # clean slate
    try
        @test QuizStudent.remembered_resume_token(url, key) === nothing
        QuizStudent.remember_resume_token!(url, key, "deadbeefcafef00d")
        @test QuizStudent.remembered_resume_token(url, key) == "deadbeefcafef00d"
        # tokens are scoped per (server, room)
        @test QuizStudent.remembered_resume_token(url, "OTHER1") === nothing
        @test QuizStudent.remembered_resume_token("ws://elsewhere", key) === nothing
        forget_resume_token!(url, key)                  # exported helper
        @test QuizStudent.remembered_resume_token(url, key) === nothing
    finally
        QuizStudent.forget_resume_token!(url, key)
    end
end
