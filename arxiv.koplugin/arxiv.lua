--[[--
Pure arXiv identifier parsing and URL policy. No KOReader dependencies.

Only post-April-2007 identifiers are supported (https://info.arxiv.org/help/arxiv_identifier.html):
  YYMM.NNNN   for 0704 through 1412 (4-digit sequence, from 0001)
  YYMM.NNNNN  from 1501 onward       (5-digit sequence, from 00001)
optionally followed by a version vV (V >= 1, no leading zero).
]]

local M = {}

M.PDF_BASE = "https://arxiv.org/pdf/"
M.MAX_INPUT = 2048

-- Exact host names accepted in pasted URLs. Downloads always use PDF_BASE.
local URL_HOSTS = {
    ["arxiv.org"] = true,
    ["www.arxiv.org"] = true,
    ["export.arxiv.org"] = true,
}

local LEGACY_PATTERN = "^[%a%-]+%.?%a*/%d%d%d%d%d%d%d"

local function parse_modern(s)
    local yy, mm, num, version = s:match("^(%d%d)(%d%d)%.(%d+)(.*)$")
    if not yy then
        if s:match(LEGACY_PATTERN) then
            return nil, "unsupported_legacy"
        end
        return nil, "invalid_format"
    end
    local month = tonumber(mm)
    if month < 1 or month > 12 then
        return nil, "invalid_month"
    end
    local yymm = tonumber(yy .. mm)
    if yymm < 704 then
        return nil, "unsupported_legacy"
    end
    local width = yymm <= 1412 and 4 or 5
    if #num ~= width or not num:match("[1-9]") then
        return nil, "invalid_number"
    end
    if version ~= "" and not version:match("^v") then
        return nil, "invalid_format"
    end
    if version ~= "" and not version:match("^v[1-9]%d*$") then
        return nil, "invalid_version"
    end
    return yy .. mm .. "." .. num .. version
end

local function parse_url(scheme, authority, path)
    if scheme ~= "https" and scheme ~= "http" then
        return nil, "invalid_url"
    end
    -- Rejects userinfo, ports, trailing dots and look-alike hosts in one check.
    if not URL_HOSTS[authority:lower()] then
        return nil, "untrusted_host"
    end
    local kind, rest = path:match("^/(%a+)/(.+)$")
    if kind ~= "abs" and kind ~= "pdf" then
        return nil, "invalid_url"
    end
    if kind == "pdf" then
        rest = rest:gsub("%.pdf$", "", 1)
    end
    return parse_modern(rest)
end

--- Parse user input into a normalized identifier.
-- @treturn string|nil normalized id, e.g. "2609.16338v2"
-- @treturn string|nil error code when parsing fails
function M.parse(input)
    if type(input) ~= "string" then
        return nil, "empty"
    end
    local s = input:match("^%s*(.-)%s*$")
    if s == "" then
        return nil, "empty"
    end
    -- Printable ASCII only: rejects control characters, non-ASCII look-alikes and
    -- whitespace inside the value; "%" rejects percent-encoded traversal outright.
    if #s > M.MAX_INPUT or s:find("[^\33-\126]") or s:find("%", 1, true) or s:find("\\", 1, true) then
        return nil, "invalid_characters"
    end
    local scheme, authority, path = s:match("^(%a[%w+.-]*)://([^/?#]*)([^?#]*)")
    if scheme then
        return parse_url(scheme:lower(), authority, path)
    end
    if s:find("://", 1, true) then
        return nil, "invalid_url"
    end
    -- Scheme-less paste such as "arxiv.org/abs/2609.16338".
    local host, host_path = s:match("^([%w.-]+)(/[^?#]*)")
    if host and URL_HOSTS[host:lower()] then
        return parse_url("https", host, host_path)
    end
    local bare = s:gsub("^[aA][rR][xX][iI][vV]:", "", 1)
    return parse_modern(bare)
end

--- Canonical download URL for a normalized id.
function M.build_pdf_url(id)
    return M.PDF_BASE .. id
end

--- File basename for a normalized id; ids contain only [0-9.v].
function M.filename(id)
    return id .. ".pdf"
end

return M
