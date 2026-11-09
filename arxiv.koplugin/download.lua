--[[--
Bounded, validated PDF download with temp-file/validate/rename finalization.

Transport (`http_request`) and filesystem (`fs`) are injected so every failure
mode is unit-testable; `M.koreader_request` and `M.real_fs` are the runtime
implementations. Nothing here touches the network or disk at load time.

Invariants:
  * bytes are only ever written to a unique hidden temp file next to the target;
  * the target path only ever receives a fully received, validated PDF;
  * an existing target is moved aside and restored if the replacement fails.
]]

local M = {}

M.MAX_BYTES = 100 * 1024 * 1024
M.MAX_REDIRECTS = 5
M.MIN_BYTES = 64
-- Shipped by KOReader; relative to its install directory (KOReader's cwd).
M.CA_BUNDLE = "data/ca-bundle.crt"

local REDIRECT_CODES = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

local function fail(code, detail)
    return { ok = false, code = code, detail = detail }
end

local function escape_pattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- True for https URLs on arxiv.org or one of its subdomains, default port, no userinfo.
function M.is_trusted_url(url)
    if type(url) ~= "string" or url:find("[^\33-\126]") then
        return false
    end
    local authority = url:match("^[hH][tT][tT][pP][sS]://([^/?#]*)")
    if not authority then
        return false
    end
    local host = authority:lower():gsub(":443$", "", 1)
    if not host:match("^[%w%.%-]+$") or host:find("..", 1, true) then
        return false
    end
    return host == "arxiv.org" or host:sub(-#".arxiv.org") == ".arxiv.org"
end

--- Resolve a Location header against the current URL. Supports absolute URLs,
-- scheme-relative ("//host/...") and absolute-path ("/...") references only.
function M.resolve_location(base, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    if location:match("^%a[%w+.-]*:") then
        return location
    end
    if location:match("^//") then
        return "https:" .. location
    end
    if location:match("^/") then
        local origin = base:match("^(%a[%w+.-]*://[^/?#]*)")
        return origin and origin .. location
    end
    return nil
end

--- RFC 6125-style match of one certificate DNS name (left-most-label wildcard only).
function M.cert_name_matches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then
        return true
    end
    local suffix = pattern:match("^%*(%.[^*]+)$")
    if not suffix or select(2, suffix:gsub("%.", "")) < 2 then
        return false
    end
    local rest = host:match("^[^.]+(%..+)$")
    return rest == suffix
end

local function classify_transport_error(err)
    err = tostring(err or "")
    if err:find("certificate") or err:find("handshake") or err:find("hostname") then
        return "tls"
    elseif err:find("timeout") then
        return "timeout"
    end
    return "network"
end

-- Remove leftovers that are provably ours, from an interrupted earlier attempt
-- for this same file: hidden temp files with our exact prefix, and the backup
-- of a replaced original (restored if the original is missing).
local function recover(fs, dir, base)
    local dest, backup = dir .. "/" .. base, dir .. "/." .. base .. ".arxiv-backup"
    if fs.exists(backup) then
        if fs.exists(dest) then
            fs.remove(backup)
        else
            fs.rename(backup, dest)
        end
    end
    local pattern = "^%." .. escape_pattern(base) .. "%.arxiv%-%x+%.part$"
    for _, name in ipairs(fs.list(dir) or {}) do
        if name:match(pattern) then
            fs.remove(dir .. "/" .. name)
        end
    end
end

local function new_temp_path(fs, dir, base, token)
    for _ = 1, 8 do
        local path = string.format("%s/.%s.arxiv-%s.part", dir, base, token())
        if not fs.exists(path) then
            return path
        end
    end
    return nil
end

local function default_token()
    return string.format("%x%06x", os.time(), math.random(0, 0xffffff))
end

-- Perform one HTTP exchange streaming the body into `temp`.
local function fetch_once(opts, url, temp)
    local fh, open_err = opts.fs.open(temp, "wb")
    if not fh then
        return nil, fail("fs_error", open_err)
    end
    local st = { bytes = 0, head = "", tail = "" }
    local function sink(chunk)
        if chunk == nil or chunk == "" then
            return 1
        end
        st.bytes = st.bytes + #chunk
        if st.bytes > opts.max_bytes then
            st.too_large = true
            return nil, "size limit exceeded"
        end
        if #st.head < 5 then
            st.head = (st.head .. chunk):sub(1, 5)
        end
        st.tail = (st.tail .. chunk):sub(-1024)
        local ok, err = fh:write(chunk)
        if not ok then
            st.write_err = err or "write failed"
            return nil, st.write_err
        end
        return 1
    end
    local ok, code, headers = pcall(opts.http_request, {
        url = url,
        headers = { ["Accept"] = "application/pdf", ["Accept-Encoding"] = "identity" },
        sink = sink,
    })
    -- Close before inspecting results: buffered write errors (e.g. ENOSPC) surface here.
    local closed, close_err = fh:close()
    if st.too_large then
        return nil, fail("too_large")
    elseif st.write_err then
        return nil, fail("fs_error", st.write_err)
    elseif not ok then
        return nil, fail(classify_transport_error(code), tostring(code))
    elseif type(code) ~= "number" then
        return nil, fail(classify_transport_error(headers), tostring(headers))
    elseif not closed then
        return nil, fail("fs_error", close_err)
    end
    return { code = code, headers = headers or {}, st = st }
end

local function validate_pdf(resp, max_bytes)
    local st = resp.st
    local length = tonumber(resp.headers["content-length"])
    if length and length > max_bytes then
        return fail("too_large")
    elseif st.bytes == 0 then
        return fail("empty")
    elseif length and length ~= st.bytes then
        return fail("truncated", string.format("%d of %d bytes", st.bytes, length))
    elseif st.head ~= "%PDF-" or st.bytes < M.MIN_BYTES then
        return fail("invalid_pdf")
    elseif not st.tail:find("%%EOF", 1, true) then
        -- Every complete PDF ends with an %%EOF marker (possibly followed by whitespace).
        return fail("truncated", "missing %%EOF")
    end
    return nil
end

local function finalize(fs, temp, dest, backup, overwrite)
    if not fs.exists(dest) then
        local ok, err = fs.rename(temp, dest)
        if not ok then
            return fail("fs_error", err)
        end
        return { ok = true, path = dest }
    end
    if not overwrite then
        return fail("exists")
    end
    local ok, err = fs.rename(dest, backup)
    if not ok then
        return fail("fs_error", err)
    end
    ok, err = fs.rename(temp, dest)
    if not ok then
        -- If this rollback fails too, recover() restores the backup next time.
        fs.rename(backup, dest)
        return fail("fs_error", err)
    end
    fs.remove(backup)
    return { ok = true, path = dest }
end

local function run(opts)
    local fs = opts.fs
    local dest = opts.destination
    local dir, base = dest:match("^(/.-)/([%w._-]+%.pdf)$")
    if not dir or base:sub(1, 1) == "." or (dir .. "/"):find("/%.%.?/") or not fs.is_dir(dir) then
        return fail("invalid_destination", dest)
    end
    if not M.is_trusted_url(opts.url) then
        return fail("untrusted_url", opts.url)
    end
    recover(fs, dir, base)
    local backup = dir .. "/." .. base .. ".arxiv-backup"

    local url, visited = opts.url, {}
    for _ = 0, opts.max_redirects do
        if visited[url] then
            return fail("redirect_loop", url)
        end
        visited[url] = true
        local temp = new_temp_path(fs, dir, base, opts.token)
        if not temp then
            return fail("fs_error", "no unique temporary name")
        end
        local resp, err = fetch_once(opts, url, temp)
        local result
        if not resp then
            result = err
        elseif REDIRECT_CODES[resp.code] then
            local next_url = M.resolve_location(url, resp.headers.location)
            if not next_url then
                result = fail("bad_redirect", "missing or unsupported Location")
            elseif not M.is_trusted_url(next_url) then
                result = fail(next_url:match("^[hH][tT][tT][pP]:") and "insecure_redirect" or "bad_redirect", next_url)
            else
                url = next_url
            end
        elseif resp.code == 404 then
            result = fail("not_found")
        elseif resp.code ~= 200 then
            result = fail("http_error", resp.code)
        else
            result = validate_pdf(resp, opts.max_bytes) or finalize(fs, temp, dest, backup, opts.overwrite)
        end
        if not (result and result.ok) then
            fs.remove(temp) -- never leaves partial data behind; harmless if already renamed
        end
        if result then
            return result
        end
    end
    return fail("too_many_redirects")
end

local active = {}

--- Download `opts.url` (trusted arXiv https URL) to `opts.destination`.
-- opts: url, destination (absolute .../<name>.pdf), http_request, fs,
--       overwrite (bool), max_bytes, max_redirects, token (temp-name generator).
-- @treturn table {ok=true, path=...} or {ok=false, code=..., detail=...}
function M.download_pdf(opts)
    opts = {
        url = opts.url,
        destination = opts.destination,
        http_request = opts.http_request or M.koreader_request,
        fs = opts.fs or M.real_fs(),
        overwrite = opts.overwrite == true,
        max_bytes = opts.max_bytes or M.MAX_BYTES,
        max_redirects = opts.max_redirects or M.MAX_REDIRECTS,
        token = opts.token or default_token,
    }
    if type(opts.destination) ~= "string" then
        return fail("invalid_destination")
    end
    if active[opts.destination] then
        return fail("busy")
    end
    active[opts.destination] = true
    local ok, result = pcall(run, opts)
    active[opts.destination] = nil
    if not ok then
        return fail("internal", tostring(result))
    end
    return result
end

--- Filesystem adapter backed by io/os and KOReader's LuaFileSystem.
function M.real_fs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then
        lfs = require("lfs")
    end
    return {
        open = io.open,
        rename = os.rename,
        remove = os.remove,
        -- symlinkattributes: a dangling symlink still counts as "exists".
        exists = function(path)
            return lfs.symlinkattributes(path, "mode") ~= nil
        end,
        is_dir = function(path)
            return lfs.attributes(path, "mode") == "directory"
        end,
        list = function(dir)
            local names = {}
            local iter_ok, iter, state = pcall(lfs.dir, dir)
            if iter_ok then
                for name in iter, state do
                    names[#names + 1] = name
                end
            end
            return names
        end,
    }
end

--- HTTP adapter for KOReader's LuaSocket/LuaSec, with certificate chain and
-- host name verification (LuaSec defaults to verify = "none" and never checks
-- host names). Redirects are not followed here; `run` applies the policy.
-- @treturn number|nil status code, or nil plus error message
-- @treturn table|string headers, or error message
function M.koreader_request(req)
    local http = require("socket.http")
    local https = require("ssl.https")
    local socketutil = require("socketutil")
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(M.CA_BUNDLE, "mode") ~= "file" then
        return nil, "certificate bundle not found: " .. M.CA_BUNDLE
    end
    local headers = { ["User-Agent"] = socketutil.USER_AGENT }
    for k, v in pairs(req.headers or {}) do
        headers[k] = v
    end
    local params = {
        url = req.url,
        method = "GET",
        headers = headers,
        sink = req.sink,
        redirect = false,
        verify = { "peer", "fail_if_no_peer_cert" },
        cafile = M.CA_BUNDLE,
    }
    local tls_create = https.tcp(params)
    params.create = function()
        local conn = tls_create()
        local connect = conn.connect
        function conn:connect(host, port)
            connect(self, host, port) -- raises (via socket.try) on TCP/TLS/chain failure
            local cert = self.sock:getpeercertificate()
            local ext = cert and cert:extensions()
            local san = ext and ext["2.5.29.17"]
            for _, name in ipairs(san and san.dNSName or {}) do
                if M.cert_name_matches(name, host) then
                    return 1
                end
            end
            return nil, "certificate hostname mismatch for " .. tostring(host)
        end
        return conn
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, r, code, resp_headers = pcall(http.request, params)
    socketutil:reset_timeout()
    if not ok then
        return nil, tostring(r)
    elseif r == nil then
        return nil, tostring(code)
    end
    return code, resp_headers
end

return M
