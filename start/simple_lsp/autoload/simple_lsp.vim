" State
let s:logs = []
let s:out_callback_buffer = ''
let s:request_id = 0
let s:requests = {}

" Utility functions
function! s:LogMsg(msg)
    call add(s:logs, a:msg)
endfunction

function! simple_lsp#GetLogs()
    return s:logs
endfunction

function! s:LSPEncode(body)
    let l:json_body = json_encode(a:body)
    return "Content-Length: ".string(len(l:json_body))."\r\n\r\n".l:json_body
endfunction

function! s:PosToLSPPos(pos)
    return {"line": a:pos[1] - 1, "character": a:pos[2] - 1}
endfunction

function! s:PathToUri(path)
    return "file://" . a:path
endfunction

function! s:UriToPath(uri)
    let l:mapping = {'%2B':'+'}
    return substitute(substitute(a:uri, "^file://", "", ''), '\('.join(keys(l:mapping), '\|').'\)' , '\=l:mapping[submatch(1)]', 'g')
endfunction

function! s:GetRequestType(id)
    let num = str2nr(a:id) 
    if num != 0 && has_key(s:requests, num)
        return s:requests[num]
    endif
    return ""
endfunction

" Base request creation
function! s:CreateLspNotification(method, params)
    return {"jsonrpc":"2.0", "method": a:method, "params": a:params}
endfunction

function! s:CreateLspRequest(method, params)
    let s:request_id += 1
    let s:requests[s:request_id] = a:method
    return {"jsonrpc":"2.0", "id":s:request_id, "method": a:method, "params": a:params}
endfunction

" Response handlers
function! s:TextDocumentDisplayDiagnostics(params)
    cgetexpr map(a:params.diagnostics, {i,v -> s:UriToPath(a:params.uri) . ":" . string(v.range.start.line + 1).":".string(v.range.start.character + 1). ":" . v.message})
endfunction

function! s:TextDocumentHandleLinks(params)
    cexpr map(a:params, {i,v -> s:UriToPath(v.uri) . ":" . string(v.range.start.line + 1).":".string(v.range.start.character + 1). ":link"})
endfunction

function! s:TextDocumentDisplayPopup(params)
    call popup_atcursor(split(a:params.contents.value, "\n"), {}) 
    echom a:params
endfunction

let s:lsp_msg_handlers = {
    \"textDocument/publishDiagnostics":function("s:TextDocumentDisplayDiagnostics"),
    \"textDocument/declaration":function("s:TextDocumentHandleLinks"),
    \"textDocument/references":function("s:TextDocumentHandleLinks"),
    \"textDocument/hover":function("s:TextDocumentDisplayPopup"),
    \}

function! s:HandleMessage(msg)
    if has_key(a:msg, "method") && has_key(s:lsp_msg_handlers, a:msg["method"])
        call s:lsp_msg_handlers[a:msg["method"]](a:msg["params"])
        return
    endif
    if has_key(a:msg, "id") && has_key(a:msg, "result") && has_key(s:lsp_msg_handlers, s:GetRequestType(a:msg.id))
        call s:lsp_msg_handlers[s:GetRequestType(a:msg.id)](a:msg["result"])
        return
    endif
    call s:LogMsg("Unrecognised:" . string(a:msg))
endfunction

" Callbacks
function! s:LspOutCallback(channel, data)
    let s:out_callback_buffer = s:out_callback_buffer . a:data
    while len(s:out_callback_buffer) > 0
        let l:prefix = 'Content-Length: '
        let l:suffix = "\r\n\r\n"
        let l:match = matchstr(s:out_callback_buffer, l:prefix . '\zs[0-9]\+\ze' . l:suffix)
        let l:header_len = len(l:prefix) + len(l:match) + len(l:suffix)
        if l:match == "" || len(s:out_callback_buffer) < l:header_len + str2nr(l:match)
            call s:LogMsg("Not enough data. buffer length: ".string(len(s:out_callback_buffer)) . ' header length: ' . string(l:header_len) . ' data length: ' . l:match)
            return
        endif
        call s:HandleMessage(json_decode(s:out_callback_buffer[l:header_len:l:header_len + str2nr(l:match) - 1]))
        let s:out_callback_buffer = s:out_callback_buffer[l:header_len + str2nr(l:match):]
    endwhile
endfunction

function! s:LspErrCallback(channel, data)
    call s:LogMsg("Err <--". a:data)
endfunction

function! s:LspExitCallback(channel, data)
    call s:LogMsg("Server exit ". a:data)
    unlet s:lsp_active
endfunction

" Server initialisation
function! s:StartServerJob(command, interval)
    let s:server_job = job_start(a:command, {
        \'out_mode':'raw',
        \'in_mode':'raw',
        \'exit_cb': 's:LspExitCallback',
        \'out_cb': 's:LspOutCallback',
        \'err_cb': 's:LspErrCallback'})
    if job_status(s:server_job) != "run"
        call s:LogMsg("Server failed to start, status: " . job_status(s:server_job))
        return 0
    endif

    let s:server_channel = job_getchannel(s:server_job)
    if ch_status(s:server_channel) != "open"
        call s:LogMsg("Server channel is not open")
        return 0
    endif

    let s:change_timer = timer_start(a:interval, 's:LSPEventLoop', {'repeat': -1})
    let s:lsp_active = 1
    return 1
endfunction

function simple_lsp#StartServer(command, rootpath)
    if exists('s:lsp_active')
        return
    endif
    if s:StartServerJob(a:command, 100)
        return simple_lsp#Send(s:CreateLspRequest("initialize", {"rootUri": s:PathToUri(a:rootPath), "capabilities": {}, "rootPath": a:rootPath}))
    endif
endfunction

" Change notification
function! s:CheckForChanges()
    if mode() != "n" || !exists('b:last_change_tick') 
        return
    endif
    if b:last_change_tick >= b:changedtick
        return
    endif

    let b:last_change_tick = b:changedtick
    let b:version += 1
    return simple_lsp#Send(s:CreateLspNotification("textDocument/didChange", {"textDocument": {"uri": s:PathToUri(expand('%:p')), "version": b:version, "languageId": "cpp"}, "contentChanges": [{'text':join(getbufline("%", 1, "$"), "\n")}]}))
endfunction

function! s:LSPEventLoop(timer)
    return s:CheckForChanges()
endfunction

" Buffer management
function! simple_lsp#UnregisterBuffer(buf)
    call s:LogMsg("Sending didClose for [".a:buf."]")
    call simple_lsp#Send(s:CreateLspNotification("textDocument/didClose", {"textDocument": {"uri": s:PathToUri(fnamemodify(bufname(a:buf), ':p')), "version": getbufvar(a:buf, 'version'), "languageId": "cpp"}}))
    return 1
endfunction

function! simple_lsp#RegisterBuffer()
    if !exists('s:lsp_active')
        return 0
    endif

    if exists('b:lsp_tracked')
        return 1
    endif

    let b:lsp_tracked = 1
    let b:version = 0
    try
        call s:LogMsg("Sending didOpen for [".bufnr()."]")
        call simple_lsp#Send(s:CreateLspNotification("textDocument/didOpen", {"textDocument": {"uri": s:PathToUri(expand('%:p')), "version": b:version, "languageId": "cpp", "text": join(getbufline('%', 1, '$'), "\n")}}))
    catch
        call s:LogMsg("Server channel not open for writing, couldn't register buffer [".expand("%:p")."]")
        return 0
    endtry
    autocmd BufLeave <buffer> let b:last_change_tick = b:changedtick
    autocmd BufDelete <buffer> call simple_lsp#UnregisterBuffer(expand('<abuf>'))
    return 1
endfunction

" Base request/notification sending
function! simple_lsp#Send(object)
    if !exists('s:lsp_active')
        call s:LogMsg("Attempt to send request when LSP is not active" . string(a:object))
        return
    endif
    return ch_sendraw(s:server_channel, s:LSPEncode(a:object))
endfunction

function! simple_lsp#SendBufferRequest(object)
    if !exists('b:lsp_tracked')
        call s:LogMsg("Attempt to send request for untracked buffer" . string(a:object))
        return
    endif
    return simple_lsp#Send(a:object)
endfunction

" Top level commands
function! simple_lsp#RequestDeclaration()
    return simple_lsp#SendBufferRequest(s:CreateLspRequest("textDocument/declaration", {"textDocument": {"uri": s:PathToUri(expand('%:p'))}, "position": s:PosToLSPPos(getcurpos())}))
endfunction

function! simple_lsp#RequestReferences()
    return simple_lsp#SendBufferRequest(s:CreateLspRequest("textDocument/references", {"textDocument": {"uri": s:PathToUri(expand('%:p'))}, "position": s:PosToLSPPos(getcurpos()), "includeDeclaration": v:true}))
endfunction

function! simple_lsp#RequestHover()
    return simple_lsp#SendBufferRequest(s:CreateLspRequest("textDocument/hover", {"textDocument": {"uri": s:PathToUri(expand('%:p'))}, "position": s:PosToLSPPos(getcurpos())}))
endfunction

function! simple_lsp#RequestCompletion()
    return simple_lsp#SendBufferRequest(s:CreateLspRequest("textDocument/completion", {"context": {"triggerKind": 1}, "textDocument": {"uri": s:PathToUri(expand('%:p'))}, "position": s:PosToLSPPos(getcurpos())}))
endfunction
