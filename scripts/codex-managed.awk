# Preserve original text while assembling Markdown or patching TOML locally.
function emit(s) {
    if (written && !terminated) printf "%s", newline
    printf "%s%s", s, newline
    written = terminated = 1
}
function original(n) {
    printf "%s", raw[n]
    terminated = n < NR || ENVIRON["DOTFILES_EOF"] == "true"
    if (terminated) printf "\n"
    written = 1
}
function flush(scope,    i,k) {
    for (i = 1; i <= count; i++) {
        k = keys[i]
        if (scopes[k] == scope && !seen[k]) {
            emit(names[k] " = " values[k]); seen[k] = 1
        }
    }
}
function agents(    i,lines,total) {
    emit("")
    emit("[agents]" (agents_comment != "" ? " " agents_comment : ""))
    total = split(ENVIRON["DOTFILES_AGENTS"], lines, "\n")
    for (i = 1; i <= total; i++) {
        emit(lines[i])
    }
    emit("")
}
function new_agents() {
    emit("")
    emit("[agents]")
    flush("agents")
    emit("")
}
# Track strings/containers so apparent declarations inside multiline values
# remain untouched. yq, not this scanner, parses the actual TOML data.
function scan(s,    i,c) {
    suffix = ""; code = s
    for (i = 1; i <= length(s); i++) {
        c = substr(s,i,1)
        if (quote != "") {
            if (escaped) { escaped = 0; continue }
            if (quote == "\"" && c == "\\") { escaped = 1; continue }
            if (multiline) {
                if (substr(s,i,3) == quote quote quote) {
                    # Consume the closing run, including an optional fourth/fifth quote.
                    while (substr(s,i+1,1) == quote) i++
                    quote = ""
                }
            } else if (c == quote) quote = ""
        } else if (c == "\"" || c == "\047") {
            quote = c; multiline = substr(s,i,3) == c c c
            if (multiline) i += 2
        } else if (c == "#") {
            suffix = substr(s,i); code = substr(s,1,i-1); break
        } else if (c == "[" || c == "{") depth++
        else if (c == "]" || c == "}") depth--
    }
    escaped = 0
}
BEGIN {
    newline = ENVIRON["DOTFILES_NEWLINE"] == "crlf" ? "\r\n" : "\n"
    start = "<!-- dotfiles:agents:start -->"; end = "<!-- dotfiles:agents:end -->"
    if (mode == "config") {
        total = split(ENVIRON["DOTFILES_SETTINGS"], settings, "\n")
        setting_scope = "root"
        for (i = 1; i <= total; i++) {
            line = settings[i]
            if (line == "[agents]") { setting_scope = "agents"; continue }
            if (line !~ /^[a-z_]+ = /) continue
            name = line; sub(/ = .*/, "", name)
            value = line; sub(/^[^=]*= /, "", value)
            k = setting_scope == "agents" ? "agents." name : name
            keys[++count] = k; values[k] = value
            names[k] = name; scopes[k] = setting_scope
        }
    } else if (mode == "instructions") {
        while ((getline line < ENVIRON["DOTFILES_BLOCK"]) > 0) block = block line "\n"
        close(ENVIRON["DOTFILES_BLOCK"])
    }
}
{
    raw[NR] = $0
    line = $0; sub(/\r$/, "", line); clean[NR] = line
    if (mode == "instructions") {
        if (index(line,start)) { starts++; from = NR; if (line != start) malformed = 1 }
        if (index(line,end)) { ends++; to = NR; if (line != end) malformed = 1 }
    } else {
        fresh = quote == "" && depth == 0
        if (fresh && line ~ /^[ \t]*[a-z_]+[ \t]*=/) {
            statement = NR
            key = line; sub(/^[ \t]*/, "", key); sub(/[ \t]*=.*/, "", key)
            declarations[NR] = key
        }
        scan(line)
        comments[NR] = suffix; codes[NR] = code
        if (fresh && line ~ /^[ \t]*\[/) {
            table = code; sub(/^[ \t]*/, "", table); sub(/[ \t]*$/, "", table)
            # Normalize only the table identity; original() retains the header text.
            if (table ~ /^\[[ \t]*agents[ \t]*\]$/) table = "[agents]"
            tables[NR] = table
            if (table == "[agents]") declared_agents++
        }
        if (statement && quote == "" && depth == 0) { last[statement] = NR; statement = 0 }
    }
}
END {
    if (mode == "instructions") {
        prefix = 0
        while (prefix < NR && clean[prefix+1] ~ /^@/) prefix++
        if (starts == 1 && ends == 1 && from < to && !malformed) {
            for (n = from; n <= to; n++) removed[n] = 1
            n = from-1
            while (n > prefix && clean[n] ~ /^[ \t]*$/) removed[n--] = 1
            n = to+1
            while (n <= NR && clean[n] ~ /^[ \t]*$/) removed[n++] = 1
            right = n; left = from-1
            while (left > prefix && removed[left]) left--
            if (left > prefix && right <= NR) join_at = from
        } else if (starts || ends) {
            print "manual review" > ENVIRON["DOTFILES_WARNING"]
            close(ENVIRON["DOTFILES_WARNING"])
        }
        for (n = 1; n <= prefix; n++) printf "%s\n", raw[n]
        printf "%s%s", newline, block
        boundary = 1
        for (n = prefix+1; n <= NR; n++) {
            if (n == join_at && !boundary) printf "%s", newline
            if (removed[n]) continue
            if (boundary && clean[n] ~ /^[ \t]*$/) continue
            boundary = 0; original(n)
        }
    } else {
        scope = "root"
        # Find the root inline declaration before deciding where to insert.
        for (n = 1; n <= NR; n++) {
            if (tables[n] != "") break
            if (declarations[n] == "agents") {
                if (inline || declared_agents) exit 1
                inline = n; agents_comment = comments[last[n]]
            }
        }
        if (declared_agents > 1) exit 1
        if (mode == "normalize") {
            for (n = 1; n <= NR; n++) {
                if (n == inline) { n = last[n]; continue }
                if (inline && !inserted && tables[n] != "") { agents(); inserted = 1 }
                original(n)
            }
            if (inline && !inserted) agents()
            exit
        }
        if (inline) exit 1
        for (n = 1; n <= NR; n++) {
            if (tables[n] != "") {
                flush(scope)
                if (scope == "root" && !declared_agents) { new_agents(); inserted = 1 }
                scope = tables[n] == "[agents]" ? "agents" : "other"
            }
            if (n == inline) { n = last[n]; continue }
            k = declarations[n]
            if (scope == "agents") k = "agents." k
            if (scope != "other" && (k in values)) {
                if (seen[k]) exit 1
                endline = last[n]
                prefix = clean[n]; sub(/=.*/, "=", prefix)
                spacing = clean[n]; sub(/^[^=]*=/,"",spacing); sub(/[^ \t].*/,"",spacing)
                gap = codes[endline]; sub(/.*[^ \t]/,"",gap)
                emit(prefix spacing values[k] gap comments[endline])
                seen[k] = 1; n = endline
            } else original(n)
        }
        flush(scope)
        if (!declared_agents && !inserted) new_agents()
    }
}
