-- KOReader runs LuaJIT (Lua 5.1 semantics).
std = "luajit"
max_line_length = 120
unused_args = false

files["arxiv.koplugin"] = {
    -- Global settings object provided by KOReader's reader.lua.
    read_globals = { "G_reader_settings" },
}

files["spec"] = {
    -- The minimal runner (spec/runner.lua) defines these busted-style globals.
    globals = { "describe", "it", "assert", "SPEC_REPO_ROOT" },
}

files["spec/integration_spec.lua"] = {
    -- Boots KOReader, which expects these process-wide globals (as reader.lua sets them).
    globals = { "G_defaults", "G_reader_settings" },
}
