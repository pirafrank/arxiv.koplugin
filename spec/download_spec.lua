local Download = require("download")

local function read_fixture(name)
    local f = assert(io.open(SPEC_REPO_ROOT .. "/spec/fixtures/" .. name, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

local PDF = read_fixture("minimal.pdf")
local HTML = read_fixture("error.html")
local URL = "https://arxiv.org/pdf/2609.16338"
local DIR = "/books"
local DEST = DIR .. "/2609.16338.pdf"

-- In-memory filesystem implementing the download.lua fs interface, with fault injection.
local function fake_fs(opts)
    opts = opts or {}
    local fs = { files = {}, dirs = { [DIR] = true }, opened = {} }
    function fs.open(path)
        if opts.open_fails then
            return nil, path .. ": Permission denied"
        end
        fs.opened[#fs.opened + 1] = path
        local parts, size = {}, 0
        fs.files[path] = ""
        return {
            write = function(_, chunk)
                if opts.space and size + #chunk > opts.space then
                    return nil, "No space left on device"
                end
                size = size + #chunk
                parts[#parts + 1] = chunk
                return true
            end,
            close = function()
                fs.files[path] = table.concat(parts)
                if opts.close_fails then
                    return nil, "Input/output error"
                end
                return true
            end,
        }
    end
    function fs.rename(from, to)
        if opts.rename_fails and opts.rename_fails(from, to) then
            return nil, "rename failed"
        end
        if fs.files[from] == nil then
            return nil, "no such file"
        end
        fs.files[to], fs.files[from] = fs.files[from], nil
        return true
    end
    function fs.remove(path)
        if opts.remove_fails and opts.remove_fails(path) then
            return nil, "remove failed"
        end
        fs.files[path] = nil
        return true
    end
    function fs.exists(path)
        return fs.files[path] ~= nil or fs.dirs[path] ~= nil or (opts.phantom and opts.phantom[path]) or false
    end
    function fs.is_dir(path)
        return fs.dirs[path] == true
    end
    function fs.list(dir)
        local names = {}
        for path in pairs(fs.files) do
            local d, name = path:match("^(.*)/([^/]+)$")
            if d == dir then
                names[#names + 1] = name
            end
        end
        return names
    end
    -- Names in DIR other than `keep`; used to prove no temp/backup leaks.
    function fs.others(keep)
        local extra = {}
        for _, name in ipairs(fs.list(DIR)) do
            if not keep or DIR .. "/" .. name ~= keep then
                extra[#extra + 1] = name
            end
        end
        return extra
    end
    return fs
end

-- Scripted HTTP transport. routes[url] = {code=, headers=, body=, chunks=, err=, raise=}
local function fake_http(routes, log)
    return function(req)
        if log then
            log[#log + 1] = req
        end
        local r = routes[req.url]
        if not r then
            return nil, "host not found"
        end
        if r.raise then
            error(r.raise)
        end
        local chunks = r.chunks or (r.body and { r.body }) or {}
        for _, chunk in ipairs(chunks) do
            local ok, err = req.sink(chunk)
            if not ok then
                return nil, err
            end
        end
        if r.err then
            return nil, r.err
        end
        req.sink(nil)
        return r.code, r.headers or {}
    end
end

local function get(routes, extra)
    local fs = (extra and extra.fs) or fake_fs()
    local o = { url = URL, destination = DEST, http_request = fake_http(routes, extra and extra.log), fs = fs }
    for k, v in pairs(extra or {}) do
        o[k] = v
    end
    return Download.download_pdf(o), fs
end

local function ok_route(body, headers)
    return { code = 200, body = body or PDF, headers = headers or { ["content-length"] = tostring(#(body or PDF)) } }
end

local function chunked(data, n)
    local t = {}
    for i = 1, #data, n do
        t[#t + 1] = data:sub(i, i + n - 1)
    end
    return t
end

describe("download_pdf success", function()
    it("saves a valid PDF and leaves no temp file", function()
        local res, fs = get({ [URL] = ok_route() })
        assert.truthy(res.ok, tostring(res.code))
        assert.equal(DEST, res.path)
        assert.equal(PDF, fs.files[DEST])
        assert.equal(0, #fs.others(DEST))
    end)

    it("handles chunked bodies without Content-Length", function()
        local res, fs = get({ [URL] = { code = 200, chunks = chunked(PDF, 7), headers = {} } })
        assert.truthy(res.ok, tostring(res.code))
        assert.equal(PDF, fs.files[DEST])
        assert.equal(0, #fs.others(DEST))
    end)

    it("sends Accept and identity encoding headers", function()
        local log = {}
        get({ [URL] = ok_route() }, { log = log })
        assert.equal("application/pdf", log[1].headers["Accept"])
        assert.equal("identity", log[1].headers["Accept-Encoding"])
    end)

    it("writes only to a hidden temp file in the same directory", function()
        local res, fs = get({ [URL] = ok_route() })
        assert.truthy(res.ok)
        assert.equal(1, #fs.opened)
        assert.truthy(fs.opened[1]:match("^/books/%.2609%.16338%.pdf%.arxiv%-%x+%.part$"), fs.opened[1])
    end)

    it("picks a fresh temp name when the candidate already exists", function()
        local tokens = { "aaaa", "aaaa", "bbbb" }
        local i = 0
        local fs = fake_fs({ phantom = { ["/books/.2609.16338.pdf.arxiv-aaaa.part"] = true } })
        local res = get({ [URL] = ok_route() }, { fs = fs, token = function() i = i + 1 return tokens[i] end })
        assert.truthy(res.ok)
        assert.equal("/books/.2609.16338.pdf.arxiv-bbbb.part", fs.opened[1])
    end)

    it("fails safely when no unique temp name can be found", function()
        local fs = fake_fs({ phantom = { ["/books/.2609.16338.pdf.arxiv-aaaa.part"] = true } })
        local res = get({ [URL] = ok_route() }, { fs = fs, token = function() return "aaaa" end })
        assert.equal("fs_error", res.code)
        assert.equal(nil, fs.files[DEST])
    end)
end)

describe("download_pdf failures leave no final file and no temp", function()
    local cases = {
        { "404", { code = 404, body = HTML }, "not_found" },
        { "403", { code = 403, body = HTML }, "http_error" },
        { "429", { code = 429, body = "" }, "http_error" },
        { "500", { code = 500, body = HTML }, "http_error" },
        { "TLS error", { err = "certificate verify failed" }, "tls" },
        { "hostname mismatch", { err = "certificate hostname mismatch for arxiv.org" }, "tls" },
        { "timeout", { err = "timeout" }, "timeout" },
        { "connection reset mid-body", { chunks = { PDF:sub(1, 100) }, err = "closed" }, "network" },
        { "transport raising", { raise = "boom" }, "network" },
        { "truncated vs Content-Length",
            { code = 200, body = PDF:sub(1, 300), headers = { ["content-length"] = tostring(#PDF) } }, "truncated" },
        { "truncated without Content-Length", { code = 200, body = PDF:sub(1, 300) }, "truncated" },
        { "empty body", { code = 200, body = "" }, "empty" },
        { "HTML with 200", ok_route(HTML), "invalid_pdf" },
        { "JSON with 200", ok_route('{"error":"not found","pad":"' .. string.rep("x", 80) .. '"}'), "invalid_pdf" },
        { "tiny PDF-like body", ok_route("%PDF-1.4\n%%EOF\n"), "invalid_pdf" },
        { "oversized Content-Length",
            { code = 200, body = PDF, headers = { ["content-length"] = "999999999999" } }, "too_large" },
    }
    for _, case in ipairs(cases) do
        it(case[1], function()
            local res, fs = get({ [URL] = case[2] })
            assert.falsy(res.ok)
            assert.equal(case[3], res.code)
            assert.equal(nil, fs.files[DEST])
            assert.equal(0, #fs.others())
        end)
    end

    it("aborts the stream once the byte limit is exceeded", function()
        local delivered = 0
        local res, fs = get({}, { max_bytes = 4096, http_request = function(req)
            for _ = 1, 1000 do
                delivered = delivered + 1
                local ok, err = req.sink(string.rep("x", 1024))
                if not ok then return nil, err end
            end
            return 200, {}
        end })
        assert.equal("too_large", res.code)
        assert.equal(5, delivered)
        assert.equal(0, #fs.others())
    end)

    it("rejects an untrusted initial URL without any request", function()
        local log = {}
        local res = get({}, { url = "https://evil.test/pdf/2609.16338", log = log })
        assert.equal("untrusted_url", res.code)
        assert.equal(0, #log)
    end)
end)

describe("download_pdf redirects", function()
    it("follows an https redirect to a trusted arxiv.org host", function()
        local res, fs = get({
            [URL] = { code = 302, headers = { location = "https://export.arxiv.org/pdf/2609.16338" }, body = HTML },
            ["https://export.arxiv.org/pdf/2609.16338"] = ok_route(),
        })
        assert.truthy(res.ok, tostring(res.code))
        assert.equal(PDF, fs.files[DEST])
        assert.equal(0, #fs.others(DEST))
    end)

    it("resolves absolute-path Location values", function()
        local res = get({
            ["https://arxiv.org/pdf/2609.16338.pdf"] = { code = 301, headers = { location = "/pdf/2609.16338" } },
            [URL] = ok_route(),
        }, { url = "https://arxiv.org/pdf/2609.16338.pdf" })
        assert.truthy(res.ok, tostring(res.code))
    end)

    local function redirect_to(location)
        return get({ [URL] = { code = 302, headers = { location = location }, body = HTML } })
    end

    it("rejects an https to http downgrade", function()
        local res, fs = redirect_to("http://arxiv.org/pdf/2609.16338")
        assert.equal("insecure_redirect", res.code)
        assert.equal(0, #fs.others())
    end)

    it("rejects untrusted hosts, credentials, ports and schemes", function()
        for _, loc in ipairs({
            "https://evil.test/x.pdf", "https://arxiv.org.evil.test/x", "https://user:pw@arxiv.org/pdf/x",
            "https://arxiv.org:8443/pdf/x", "ftp://arxiv.org/x", "//evil.test/x", "file:///etc/passwd",
        }) do
            local res, fs = redirect_to(loc)
            assert.equal("bad_redirect", res.code, loc)
            assert.equal(0, #fs.others(), loc)
        end
    end)

    it("rejects missing and relative-path Location", function()
        assert.equal("bad_redirect", get({ [URL] = { code = 302, headers = {} } }).code)
        assert.equal("bad_redirect", redirect_to("other.pdf").code)
    end)

    it("detects redirect loops", function()
        local res, fs = get({
            [URL] = { code = 302, headers = { location = "https://arxiv.org/pdf/b" } },
            ["https://arxiv.org/pdf/b"] = { code = 307, headers = { location = URL } },
        })
        assert.equal("redirect_loop", res.code)
        assert.equal(0, #fs.others())
    end)

    it("stops after too many hops", function()
        local routes = {}
        for i = 0, 10 do
            local from = i == 0 and URL or ("https://arxiv.org/pdf/hop" .. i)
            routes[from] = { code = 302, headers = { location = "https://arxiv.org/pdf/hop" .. (i + 1) } }
        end
        local res, fs = get(routes)
        assert.equal("too_many_redirects", res.code)
        assert.equal(0, #fs.others())
    end)
end)

describe("download_pdf existing files", function()
    local OLD = "%PDF-1.4 old original bytes"

    local function with_existing(opts)
        local fs = fake_fs(opts)
        fs.files[DEST] = OLD
        return fs
    end

    it("never replaces an existing file without overwrite", function()
        local fs = with_existing()
        local res = get({ [URL] = ok_route() }, { fs = fs })
        assert.equal("exists", res.code)
        assert.equal(OLD, fs.files[DEST])
        assert.equal(0, #fs.others(DEST))
    end)

    it("replaces with overwrite and removes the backup", function()
        local fs = with_existing()
        local res = get({ [URL] = ok_route() }, { fs = fs, overwrite = true })
        assert.truthy(res.ok)
        assert.equal(PDF, fs.files[DEST])
        assert.equal(0, #fs.others(DEST))
    end)

    it("keeps the original on any failed replacement", function()
        local failing = {
            { code = 404, body = HTML }, ok_route(HTML), { err = "timeout" },
            { chunks = { PDF:sub(1, 50) }, err = "closed" },
        }
        for _, route in ipairs(failing) do
            local fs = with_existing()
            local res = get({ [URL] = route }, { fs = fs, overwrite = true })
            assert.falsy(res.ok)
            assert.equal(OLD, fs.files[DEST])
            assert.equal(0, #fs.others(DEST))
        end
    end)

    it("rolls back when moving the new file into place fails", function()
        local fs = with_existing({ rename_fails = function(from, to) return to == DEST and from:match("%.part$") end })
        local res = get({ [URL] = ok_route() }, { fs = fs, overwrite = true })
        assert.equal("fs_error", res.code)
        assert.equal(OLD, fs.files[DEST])
        assert.equal(0, #fs.others(DEST))
    end)

    it("keeps the original when it cannot be moved aside", function()
        local fs = with_existing({ rename_fails = function(from) return from == DEST end })
        local res = get({ [URL] = ok_route() }, { fs = fs, overwrite = true })
        assert.equal("fs_error", res.code)
        assert.equal(OLD, fs.files[DEST])
        assert.equal(0, #fs.others(DEST))
    end)
end)

describe("download_pdf filesystem errors", function()
    it("reports an unwritable directory", function()
        local res, fs = get({ [URL] = ok_route() }, { fs = fake_fs({ open_fails = true }) })
        assert.equal("fs_error", res.code)
        assert.equal(0, #fs.others())
    end)

    it("reports no space left and cleans up", function()
        local res, fs = get({ [URL] = ok_route() }, { fs = fake_fs({ space = 100 }) })
        assert.equal("fs_error", res.code)
        assert.equal(0, #fs.others())
    end)

    it("reports flush/close errors and cleans up", function()
        local res, fs = get({ [URL] = ok_route() }, { fs = fake_fs({ close_fails = true }) })
        assert.equal("fs_error", res.code)
        assert.equal(0, #fs.others())
    end)

    it("reports a failed final rename and cleans up", function()
        local res, fs = get({ [URL] = ok_route() }, { fs = fake_fs({ rename_fails = function() return true end }) })
        assert.equal("fs_error", res.code)
        assert.equal(0, #fs.others())
    end)

    it("rejects invalid destinations", function()
        for _, dest in ipairs({ "relative/2609.16338.pdf", "/books/2609.16338.txt", "/missing/2609.16338.pdf",
            "/books/../etc/x.pdf", "/books/.hidden.pdf", "/books/", 42 }) do
            local res = get({ [URL] = ok_route() }, { destination = dest })
            assert.equal("invalid_destination", res.code, tostring(dest))
        end
    end)
end)

describe("download_pdf recovery of interrupted attempts", function()
    it("stops before transfer if backup restoration fails", function()
        local fs = fake_fs({ rename_fails = function() return true end })
        local backup = "/books/.2609.16338.pdf.arxiv-backup"
        fs.files[backup] = "%PDF-original"
        local calls = 0
        local res = get({}, { fs = fs, overwrite = true, http_request = function()
            calls = calls + 1
        end })
        assert.equal("fs_error", res.code)
        assert.equal("%PDF-original", fs.files[backup])
        assert.equal(nil, fs.files[DEST])
        assert.equal(0, calls)
        assert.equal(0, #fs.opened)
    end)

    it("stops before transfer if backup or stale temp removal fails", function()
        for _, leftover in ipairs({
            "/books/.2609.16338.pdf.arxiv-backup",
            "/books/.2609.16338.pdf.arxiv-5f00aa.part",
        }) do
            local fs = fake_fs({ remove_fails = function() return true end })
            fs.files[DEST] = "%PDF-current"
            fs.files[leftover] = "retained bytes"
            local calls = 0
            local res = get({}, { fs = fs, overwrite = true, http_request = function()
                calls = calls + 1
            end })
            assert.equal("fs_error", res.code)
            assert.equal("%PDF-current", fs.files[DEST])
            assert.equal("retained bytes", fs.files[leftover])
            assert.equal(0, calls)
            assert.equal(0, #fs.opened)
        end
    end)

    it("removes only its own stale temp files", function()
        local fs = fake_fs()
        fs.files["/books/.2609.16338.pdf.arxiv-5f00aa.part"] = "partial"
        fs.files["/books/.2609.16338v2.pdf.arxiv-5f00aa.part"] = "other id"
        fs.files["/books/other.pdf.part"] = "not ours"
        fs.files["/books/notes.txt"] = "user file"
        local res = get({ [URL] = ok_route() }, { fs = fs })
        assert.truthy(res.ok)
        assert.equal(nil, fs.files["/books/.2609.16338.pdf.arxiv-5f00aa.part"])
        assert.equal("other id", fs.files["/books/.2609.16338v2.pdf.arxiv-5f00aa.part"])
        assert.equal("not ours", fs.files["/books/other.pdf.part"])
        assert.equal("user file", fs.files["/books/notes.txt"])
    end)

    it("restores a backup left by an interrupted replacement", function()
        local fs = fake_fs()
        fs.files["/books/.2609.16338.pdf.arxiv-backup"] = "%PDF-original"
        local res = get({ [URL] = { code = 500 } }, { fs = fs })
        assert.equal("http_error", res.code)
        assert.equal("%PDF-original", fs.files[DEST])
        assert.equal(0, #fs.others(DEST))
    end)
end)

describe("download_pdf concurrency and retry", function()
    it("refuses a second concurrent download of the same file", function()
        local inner
        local res = get({}, { http_request = function(req)
            inner = get({ [URL] = ok_route() })
            req.sink(PDF)
            return 200, {}
        end })
        assert.truthy(res.ok, tostring(res.code))
        assert.equal("busy", inner.code)
    end)

    it("releases the guard after failure so a retry works", function()
        assert.equal("network", get({ [URL] = { raise = "offline" } }).code)
        assert.truthy(get({ [URL] = ok_route() }).ok)
    end)
end)

describe("download helpers", function()
    it("trusts only https arxiv.org hosts", function()
        assert.truthy(Download.is_trusted_url("https://arxiv.org/pdf/1"))
        assert.truthy(Download.is_trusted_url("https://export.arxiv.org/pdf/1"))
        assert.truthy(Download.is_trusted_url("https://arxiv.org:443/pdf/1"))
        assert.falsy(Download.is_trusted_url("http://arxiv.org/pdf/1"))
        assert.falsy(Download.is_trusted_url("https://evilarxiv.org/pdf/1"))
        assert.falsy(Download.is_trusted_url("https://arxiv.org..evil/pdf"))
        assert.falsy(Download.is_trusted_url("https://a@arxiv.org/"))
    end)

    it("matches certificate names conservatively", function()
        assert.truthy(Download.cert_name_matches("arxiv.org", "arxiv.org"))
        assert.truthy(Download.cert_name_matches("*.arxiv.org", "export.arxiv.org"))
        assert.falsy(Download.cert_name_matches("*.arxiv.org", "arxiv.org"))
        assert.falsy(Download.cert_name_matches("*.arxiv.org", "a.b.arxiv.org"))
        assert.falsy(Download.cert_name_matches("*.org", "arxiv.org"))
        assert.falsy(Download.cert_name_matches("*.badssl.com", "wrong.host.badssl.com"))
        assert.falsy(Download.cert_name_matches("a*.arxiv.org", "ab.arxiv.org"))
    end)

    it("does no I/O at module load", function()
        local loaded = dofile(SPEC_REPO_ROOT .. "/arxiv.koplugin/download.lua")
        assert.equal("function", type(loaded.download_pdf))
    end)
end)
