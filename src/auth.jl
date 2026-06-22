# Resume-token storage. When a student first joins a room the server issues a private
# resume token that re-binds them to the same identity (and their already-answered
# state) if they drop and rejoin within the room's grace window. We persist it in this
# package's LocalPreferences.toml, keyed by server + room, so reconnecting is automatic
# and the student never has to copy a token around. Tokens are per-room and ephemeral;
# a stale one simply yields a fresh identity on the next join.

const _RESUME_KEY = "resume_tokens"

_room_id(url, room_key) = string(url, "|", room_key)

# --- server URL --------------------------------------------------------------------
# Remembered so `join_quiz(room_key=…, name=…)` can omit `url` after the first time.
# `QUIZ_URL` is honored as a fallback.

const _URL_KEY = "server_url"

"The saved server URL (LocalPreferences.toml, else `QUIZ_URL`, else `\"\"`)."
function server_url()
    saved = @load_preference(_URL_KEY, "")
    isempty(saved) ? get(ENV, "QUIZ_URL", "") : saved
end

"""
    set_url!(url) -> String

Persist the server URL so `join_quiz` can omit it on later sessions.
"""
set_url!(url::AbstractString) = (@set_preferences!(_URL_KEY => String(url)); String(url))

"Forget the saved server URL."
forget_url!() = (@delete_preferences!(_URL_KEY); nothing)

"The saved resume token for `(url, room_key)`, or `nothing`."
function remembered_resume_token(url::AbstractString, room_key::AbstractString)
    d = @load_preference(_RESUME_KEY, Dict{String,Any}())
    v = get(d, _room_id(url, room_key), nothing)
    v === nothing ? nothing : String(v)
end

"Persist the resume token for `(url, room_key)`."
function remember_resume_token!(url::AbstractString, room_key::AbstractString, token::AbstractString)
    d = Dict{String,Any}(@load_preference(_RESUME_KEY, Dict{String,Any}()))
    d[_room_id(url, room_key)] = String(token)
    @set_preferences!(_RESUME_KEY => d)
    return String(token)
end

"""
    forget_resume_token!(url, room_key)

Drop the saved resume token for a room (e.g. to rejoin as a brand-new participant).
"""
function forget_resume_token!(url::AbstractString, room_key::AbstractString)
    d = Dict{String,Any}(@load_preference(_RESUME_KEY, Dict{String,Any}()))
    if haskey(d, _room_id(url, room_key))
        delete!(d, _room_id(url, room_key))
        @set_preferences!(_RESUME_KEY => d)
    end
    return nothing
end
