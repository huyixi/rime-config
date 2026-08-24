-- rime.lua
-- 自动中英混排空格：中↔英/数、常见符号、数↔单位、全角括号外侧空格
-- 需要 librime-lua，Squirrel 新版一般自带

local utf8 = require("utf8")

-- ===== 字符分类 =====
local function is_cjk(cp)
    return (cp >= 0x4E00 and cp <= 0x9FFF)   -- CJK Unified
        or (cp >= 0x3400 and cp <= 0x4DBF)   -- CJK Ext A
        or (cp >= 0x20000 and cp <= 0x2A6DF) -- CJK Ext B
        or (cp >= 0x2A700 and cp <= 0x2B73F) -- CJK Ext C
        or (cp >= 0x2B740 and cp <= 0x2B81F) -- CJK Ext D
        or (cp >= 0x2B820 and cp <= 0x2CEAF) -- CJK Ext E/F
        or (cp >= 0xF900 and cp <= 0xFAFF)   -- CJK Compatibility Ideographs
end

local function is_ascii_letter(cp)
    return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)
end

local function is_ascii_digit(cp)
    return (cp >= 0x30 and cp <= 0x39)
end

local function is_ascii_alnum(cp) return is_ascii_letter(cp) or is_ascii_digit(cp) end

-- 作为“拉丁符号”的集合（与中文相邻时推荐留空）
local latin_symbols = {}
do
    local syms = { 35, 36, 37, 38, 42, 43, 45, 47, 61, 64, 94, 95, 124 } -- # $ % & * + - / = @ ^ _ |
    for _, cp in ipairs(syms) do latin_symbols[cp] = true end
end

local function is_latin_symbol(cp) return latin_symbols[cp] == true end

local function is_space(cp) return cp == 0x20 end

-- 中文全角括号
local CP_LPAREN_F = 0xFF08 -- （
local CP_RPAREN_F = 0xFF09 -- ）

-- 度数符号与百分号（紧贴数字）
local CP_DEGREE = 0x00B0 -- °
local CP_PERCENT = 0x25  -- %

-- 常见“推荐与数字留空”的英文单位白名单（大小写均可）
local unit_whitelist = {
    B = true,
    KB = true,
    MB = true,
    GB = true,
    TB = true,
    PB = true,
    Hz = true,
    kHz = true,
    MHz = true,
    GHz = true,
    s = true,
    ms = true,
    us = true,
    ns = true,
    min = true,
    h = true,
    m = true,
    cm = true,
    mm = true,
    km = true,
    g = true,
    mg = true,
    kg = true,
    L = true,
    mL = true,
    px = true,
    pt = true,
    dpi = true,
    W = true,
    kW = true,
    V = true,
    A = true,
    -- 你可按需追加
}

local function lower(s) return string.lower(s) end

-- 收集 UTF-8 码点
local function to_cps(s)
    local cps = {}
    for _, cp in utf8.codes(s) do table.insert(cps, cp) end
    return cps
end

local function from_cps(cps)
    local t = {}
    for i = 1, #cps do
        if type(cps[i]) == "string" then
            table.insert(t, cps[i])
        else
            table.insert(t, utf8.char(cps[i]))
        end
    end
    return table.concat(t)
end

-- 读取从 i+1 开始的一段连续 ASCII 字母，返回字符串与长度
local function read_ascii_letters(cps, i)
    local j = i + 1
    local buf = {}
    while j <= #cps and is_ascii_letter(cps[j]) do
        table.insert(buf, string.char(cps[j]))
        j = j + 1
    end
    return table.concat(buf), j - (i + 1)
end

-- 读取从 i+1 开始的一段连续 ASCII 数字，返回字符串与长度
local function read_ascii_digits(cps, i)
    local j = i + 1
    local buf = {}
    while j <= #cps and is_ascii_digit(cps[j]) do
        table.insert(buf, string.char(cps[j]))
        j = j + 1
    end
    return table.concat(buf), j - (i + 1)
end

-- 判断是否需要在 a 与 b 之间加空格（处理中↔英/数/符号）
local function need_space_cjk_ascii(a, b)
    -- 中↔英/数字
    if is_cjk(a) and (is_ascii_alnum(b) or is_latin_symbol(b)) then return true end
    if (is_ascii_alnum(a) or is_latin_symbol(a)) and is_cjk(b) then return true end
    return false
end

local function insert_spaces(text)
    local cps = to_cps(text)
    if #cps <= 1 then return text end

    local out = {}
    local i = 1
    while i <= #cps do
        local cp = cps[i]

        -- 规则 5：全角括号外侧空格（外侧，不影响括号内部）
        if cp == CP_LPAREN_F then
            -- 左侧若非开头且非空格，补一个空格
            if #out > 0 and out[#out] ~= " " then table.insert(out, " ") end
            table.insert(out, utf8.char(cp))
            i = i + 1
            goto continue
        elseif cp == CP_RPAREN_F then
            table.insert(out, utf8.char(cp))
            -- 右侧若不是末尾、且下一个不是空格/标点，则补一个空格
            local nxt = cps[i + 1]
            if nxt and nxt ~= 0x20 and not is_latin_symbol(nxt) and not is_ascii_alnum(nxt) and not is_cjk(nxt) then
                -- 如果是中文标点就不加
            else
                if nxt and nxt ~= 0x20 then table.insert(out, " ") end
            end
            i = i + 1
            goto continue
        end

        -- 规则 4（部分）：数字 + 单位白名单（如 1TB -> 1 TB；1dpi -> 1 dpi）
        if is_ascii_digit(cp) then
            -- 向前回看：不要破坏科学计数法如 1e10（我们只处理“数字紧跟字母开头”的场景）
            local nxt = cps[i + 1]
            if nxt and is_ascii_letter(nxt) then
                local unit, len = read_ascii_letters(cps, i)
                -- unit 是从 i+1 开始的字母串
                local unit_full = string.char(nxt) .. string.sub(unit, 2)
                if unit_whitelist[unit_full] or unit_whitelist[lower(unit_full)] then
                    -- 若原本没有空格，则插一个
                    table.insert(out, utf8.char(cp))
                    table.insert(out, " ")
                    -- 把后续字母原样抄过去
                    local j = i + 1
                    while j <= i + len do
                        table.insert(out, utf8.char(cps[j]))
                        j = j + 1
                    end
                    i = i + len + 1
                    goto continue
                end
            end
        end

        -- 规则 3：数字 与 % / °C 的贴合（不加空格），以及 % 与中文的分离
        if is_ascii_digit(cp) then
            local nxt = cps[i + 1]
            if nxt == CP_PERCENT then
                -- 紧贴数字：20%
                table.insert(out, utf8.char(cp))
                table.insert(out, utf8.char(nxt))
                -- % 之后若接中文/英文，留一个空格（例如 "20% 的"）
                local nxt2 = cps[i + 2]
                if nxt2 and (is_cjk(nxt2) or is_ascii_alnum(nxt2)) then table.insert(out, " ") end
                i = i + 2
                goto continue
            elseif nxt == CP_DEGREE then
                -- 处理 °C 紧贴：25°C
                local nxt2 = cps[i + 2]
                if nxt2 and (nxt2 == 0x43 or nxt2 == 0x63) then -- 'C' or 'c'
                    table.insert(out, utf8.char(cp))
                    table.insert(out, utf8.char(nxt))
                    table.insert(out, utf8.char(nxt2))
                    -- 后面若接中文/英文，留空格（如 "25°C 今天"）
                    local nxt3 = cps[i + 3]
                    if nxt3 and (is_cjk(nxt3) or is_ascii_alnum(nxt3)) then table.insert(out, " ") end
                    i = i + 3
                    goto continue
                end
            end
        end

        -- 规则 1/2/3：中↔英/数/拉丁符号 边界加空格
        local prev_cp = nil
        if #out > 0 then
            local last = out[#out]
            prev_cp = type(last) == "string" and string.byte(last) or nil
            -- 如果上一个是字符串" "（空格），prev_cp 留空即可，由边界再判断
        end

        -- 因为 out 里可能混入 " "，无法直接取 prev_cp 的码点。
        -- 改为：查看原串的相邻关系：当前 cp 与下一个 cps[i+1]
        local nxt = cps[i + 1]
        table.insert(out, utf8.char(cp))
        if nxt then
            if need_space_cjk_ascii(cp, nxt) then
                -- 避免重复空格
                if out[#out] ~= " " then table.insert(out, " ") end
            end
        end

        ::continue::
        i = i
        i = i + 1
    end

    -- 二次清理：合并多余空格
    local s = from_cps(out)
    s = s:gsub(" +", " ")
    -- 括号前若出现多余空格（" （"），保留一个即可；已经处理过，这里稳妥再收口
    s = s:gsub(" ％", "％") -- 防御性：全角百分号（很少用）
    return s
end

local function autospacer_filter(input, env)
    for cand in input:iter() do
        local t = cand.text
        -- 只处理可能含有 CJK/ASCII 的候选
        local ok = false
        for _, cp in utf8.codes(t) do
            if is_cjk(cp) or is_ascii_alnum(cp) or is_latin_symbol(cp)
                or cp == CP_LPAREN_F or cp == CP_RPAREN_F or cp == CP_DEGREE or cp == CP_PERCENT then
                ok = true; break
            end
        end
        if ok then
            local spaced = insert_spaces(t)
            if spaced ~= t then
                local nc = cand:clone()
                nc.text = spaced
                yield(nc)
            else
                yield(cand)
            end
        else
            yield(cand)
        end
    end
end

return autospacer_filter
